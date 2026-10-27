//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/quest"
	"github.com/alexivison/questmaster/internal/state"
)

// MutationCommandRunner runs a qm command for serve mutations that belong to
// the CLI/session lifecycle path.
type MutationCommandRunner interface {
	RunMutationCommand(context.Context, []string, []byte) ([]byte, error)
}

type selfMutationCommandRunner struct{}

var mutationOperationTimeout = 30 * time.Second

func (selfMutationCommandRunner) RunMutationCommand(ctx context.Context, args []string, stdin []byte) ([]byte, error) {
	exe, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("resolve running executable: %w", err)
	}
	cmd := exec.CommandContext(ctx, exe, args...)
	cmd.Env = os.Environ()
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = strings.TrimSpace(stdout.String())
		}
		if detail != "" {
			return nil, fmt.Errorf("qm %s: %w: %s", strings.Join(args, " "), err, detail)
		}
		return nil, fmt.Errorf("qm %s: %w", strings.Join(args, " "), err)
	}
	return stdout.Bytes(), nil
}

type mutationPayload struct {
	ID        string `json:"id"`
	SessionID string `json:"session_id"`
	TargetID  string `json:"target_id"`
	MasterID  string `json:"master_id"`
	Name      string `json:"name"`
	Body      string `json:"body"`
	Content   string `json:"content"`
	Message   string `json:"message"`
	Scope     string `json:"scope"`
	Repo      string `json:"repo"`
	RepoID    string `json:"repo_identity"`
	Title     string `json:"title"`
	Cwd       string `json:"cwd"`
	Agent     string `json:"agent"`
	// Decode only to reject old start/spawn clients explicitly.
	LegacyPrimary   json.RawMessage `json:"primary"`
	Role            string          `json:"role"`
	Color           string          `json:"color"`
	Class           string          `json:"class"`
	Shell           string          `json:"shell"`
	Model           string          `json:"model"`
	ReasoningEffort string          `json:"reasoning_effort"`
	Prompt          string          `json:"prompt"`
	QuestIDs        string          `json:"quest_ids"`
	QuestID         string          `json:"quest_id"`
	Path            string          `json:"path"`
	ProjectID       string          `json:"project_id"`
	ProjectPath     string          `json:"project_path"`
	ProjectName     string          `json:"project_name"`
	ProjectChanged  string          `json:"project_changed"`
	Extra           map[string]any  `json:"-"`
}

type mutationHandler func(*Server, context.Context, Request, mutationPayload) (any, error)

// Mutation execution has two deliberately separate models:
// 1. in-process mutations that call core packages directly,
// 2. re-execed qm commands for session lifecycle.
// New methods should pick one model explicitly instead of crossing layers.
var mutationRegistry = map[string]mutationHandler{
	"delete":   mutateDelete,
	"continue": mutateContinue,
	"spawn": func(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateSpawn(ctx, req, payload)
	},
	"start": func(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateStart(ctx, req, payload)
	},
	"rename": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateRename(payload)
	},
	"recolor": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateRecolor(payload)
	},
	"reclass": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateReclass(payload)
	},
	"role_default.set": func(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateRoleDefaultSet(ctx, payload)
	},
	"quest.add": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateQuestAdd(payload)
	},
	"quest.edit": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateQuestEdit(payload)
	},
	"quest.delete": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateQuestDelete(payload)
	},
	"artifact.delete": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateArtifactDelete(payload)
	},
}

func mutationMethodNames() []string {
	names := make([]string, 0, len(mutationRegistry))
	for method := range mutationRegistry {
		names = append(names, method)
	}
	sort.Strings(names)
	return names
}

func isMutationMethod(method string) bool {
	_, ok := mutationRegistry[canonicalMutationMethod(method)]
	return ok
}

func (s *Server) mutationResponse(ctx context.Context, req Request) Envelope {
	mutationCtx := ctx
	cancel := func() {}
	if mutationOperationTimeout > 0 {
		mutationCtx, cancel = context.WithTimeout(ctx, mutationOperationTimeout)
	}
	defer cancel()
	data, err := s.mutate(mutationCtx, req)
	if err != nil {
		return errorEnvelope(req.ID, err)
	}
	return Envelope{Type: "response", ID: req.ID, OK: boolPtr(true), Topic: req.Method, Data: data}
}

func (s *Server) mutate(ctx context.Context, req Request) (any, error) {
	method := canonicalMutationMethod(req.Method)
	payload, err := decodeMutationPayload(req.Data)
	if err != nil {
		return nil, err
	}
	if payload.LegacyPrimary != nil && (method == "start" || method == "spawn") {
		return nil, fmt.Errorf("unsupported field %q; use %q", "primary", "agent")
	}
	handler, ok := mutationRegistry[method]
	if !ok {
		return nil, fmt.Errorf("unknown mutation method %q", req.Method)
	}
	return handler(s, ctx, req, payload)
}

func canonicalMutationMethod(method string) string {
	if strings.HasPrefix(method, "mutation.") {
		return strings.TrimPrefix(method, "mutation.")
	}
	return method
}

func decodeMutationPayload(raw json.RawMessage) (mutationPayload, error) {
	var payload mutationPayload
	if len(bytes.TrimSpace(raw)) == 0 {
		return payload, nil
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return mutationPayload{}, fmt.Errorf("decode mutation data: %w", err)
	}
	return payload, nil
}

func mutateDelete(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"delete", sessionID}, nil)
}

func mutateContinue(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"continue", sessionID}, nil)
}

func (s *Server) mutateSpawn(ctx context.Context, req Request, payload mutationPayload) (any, error) {
	args := []string{"spawn", "--from-app"}
	if cwd := strings.TrimSpace(payload.Cwd); cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	if agent := strings.TrimSpace(payload.Agent); agent != "" {
		args = append(args, "--agent", agent)
	}
	// An empty model leaves the harness's role default in place; any non-empty
	// value is passed through untouched, so a model Questmaster has never
	// heard of still launches.
	if model := strings.TrimSpace(payload.Model); model != "" {
		args = append(args, "--model", model)
	}
	if effort := strings.TrimSpace(payload.ReasoningEffort); effort != "" {
		args = append(args, "--reasoning-effort", effort)
	}
	var stdin []byte
	if strings.TrimSpace(payload.Prompt) != "" {
		args = append(args, "--prompt-file", "-")
		stdin = []byte(payload.Prompt)
	}
	positionals := make([]string, 0, 2)
	if masterID := strings.TrimSpace(payload.MasterID); masterID != "" {
		positionals = append(positionals, masterID)
	}
	if title := strings.TrimSpace(firstNonEmpty(payload.Title, payload.Name)); title != "" {
		positionals = append(positionals, title)
	}
	if len(positionals) > 0 {
		args = append(args, "--")
		args = append(args, positionals...)
	}
	return s.runCommandJSON(ctx, args, stdin)
}

func (s *Server) mutateStart(ctx context.Context, req Request, payload mutationPayload) (any, error) {
	args := []string{"start", "--from-app"}
	cwd := strings.TrimSpace(payload.Cwd)
	prompt := payload.Prompt
	if ids := strings.Fields(payload.QuestIDs); len(ids) > 0 {
		if strings.TrimSpace(payload.Prompt) != "" || mutationTruthy(payload.Shell) {
			return nil, fmt.Errorf("quest IDs cannot be combined with prompt or shell")
		}
		quests, err := quest.LoadByID(s.mutationStore().Root(), ids)
		if err != nil {
			return nil, err
		}
		cwd, prompt, err = quest.StartPayload(quests)
		if err != nil {
			return nil, err
		}
	}
	if cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	if agent := strings.TrimSpace(payload.Agent); agent != "" {
		args = append(args, "--agent", agent)
	}
	// A shell session runs no agent, so it takes no model: --model is simply
	// never appended here rather than forwarded for the CLI to reject (the CLI
	// itself does separately reject the combination via
	// validateShellSessionFlags, but only when both flags reach it together —
	// which this branch ensures never happens over the app's mutation path).
	if model := strings.TrimSpace(payload.Model); model != "" && !mutationTruthy(payload.Shell) {
		args = append(args, "--model", model)
	}
	// Mirrors the model guard above: a shell session takes no reasoning
	// effort either, so it is never forwarded rather than left for the CLI to
	// reject.
	if effort := strings.TrimSpace(payload.ReasoningEffort); effort != "" && !mutationTruthy(payload.Shell) {
		args = append(args, "--reasoning-effort", effort)
	}
	if color := strings.TrimSpace(payload.Color); color != "" {
		args = append(args, "--color", color)
	}
	if class := strings.TrimSpace(payload.Class); class != "" {
		args = append(args, "--class", class)
	}
	if mutationTruthy(payload.Shell) {
		args = append(args, "--shell")
	}
	var stdin []byte
	if strings.TrimSpace(prompt) != "" {
		args = append(args, "--prompt-file", "-")
		stdin = []byte(prompt)
	}
	if title := strings.TrimSpace(firstNonEmpty(payload.Title, payload.Name)); title != "" {
		args = append(args, "--", title)
	}
	return s.runCommandJSON(ctx, args, stdin)
}

func (s *Server) mutateRename(payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.TargetID, payload.ID)
	if err != nil {
		return nil, err
	}
	title, err := requiredValue("title", payload.Title)
	if err != nil {
		return nil, err
	}
	if err := s.mutationStore().Update(sessionID, func(m *state.Manifest) {
		m.Title = title
		m.SetExtra("title_locked", "1")
		delete(m.Extra, "title_provisional")
	}); err != nil {
		return nil, err
	}
	return map[string]string{"session_id": sessionID, "title": title}, nil
}

func (s *Server) mutateRecolor(payload mutationPayload) (any, error) {
	color, err := mutationDisplayColor(payload.Color)
	if err != nil {
		return nil, err
	}

	store := s.mutationStore()
	switch strings.ToLower(strings.TrimSpace(payload.Scope)) {
	case "session":
		sessionID, err := requiredFirst("session_id", payload.SessionID, payload.TargetID, payload.ID)
		if err != nil {
			return nil, err
		}
		if err := store.SetDisplayColor(sessionID, color); err != nil {
			return nil, err
		}
		return map[string]string{"scope": "session", "session_id": sessionID, "color": color}, nil
	case "repo":
		repoIdentity, err := requiredFirst("repo_identity", payload.RepoID, payload.Repo, payload.TargetID, payload.ID)
		if err != nil {
			return nil, err
		}
		if err := state.NewRepoColorStore(store.Root()).Set(repoIdentity, color); err != nil {
			return nil, err
		}
		return map[string]string{"scope": "repo", "repo_identity": repoIdentity, "color": color}, nil
	default:
		return nil, fmt.Errorf("scope is required (want session or repo)")
	}
}

func (s *Server) mutateReclass(payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.TargetID, payload.ID)
	if err != nil {
		return nil, err
	}
	class, err := state.ValidateSessionClass(payload.Class)
	if err != nil {
		return nil, err
	}
	if err := s.mutationStore().SetSessionClass(sessionID, class); err != nil {
		return nil, err
	}
	return map[string]any{"session_id": sessionID, "class": class, "reclassified": true}, nil
}

// mutateRoleDefaultSet persists a default model and/or reasoning effort for
// one agent+role pair. Settings is the sole source of a default, so at least
// one field is required — there is no hardcoded fallback left to clear back
// to, and this call never deletes a persisted entry.
func (s *Server) mutateRoleDefaultSet(ctx context.Context, payload mutationPayload) (any, error) {
	agentName, err := requiredValue("agent", payload.Agent)
	if err != nil {
		return nil, err
	}
	agentName = strings.ToLower(strings.TrimSpace(agentName))
	if !slices.Contains(agent.Names(), agentName) {
		return nil, fmt.Errorf("unknown agent %q (want one of %s)", agentName, strings.Join(agent.Names(), ", "))
	}

	role := strings.ToLower(strings.TrimSpace(payload.Role))
	switch role {
	case "worker", "master":
	default:
		return nil, fmt.Errorf("role is required (want master or worker)")
	}

	model := strings.TrimSpace(payload.Model)
	reasoningEffort := strings.TrimSpace(payload.ReasoningEffort)
	if model == "" && reasoningEffort == "" {
		return nil, fmt.Errorf("model or reasoning_effort is required")
	}

	// Set() replaces the whole persisted record, so a caller that only means
	// to touch one field must not have the other silently wiped: a blank
	// field here means "leave whatever is already persisted for it," not
	// "clear it" (there is no clear-an-existing-field pathway at all — see
	// the doc comment above).
	store := state.NewRoleDefaultsStore(s.mutationStore().Root())
	existing, hasExisting, _ := store.Get(agentName, role)
	modelChanged := hasExisting && model != "" && model != existing.Model
	if model == "" && hasExisting {
		model = existing.Model
	}
	if reasoningEffort == "" && hasExisting {
		reasoningEffort = existing.ReasoningEffort
	}

	if reasoningEffort != "" {
		if err := agent.ValidateReasoningEffort(agentName, model, reasoningEffort, s.resolveReasoningEfforts(ctx, agentName, model)); err != nil {
			if !modelChanged || reasoningEffort != existing.ReasoningEffort {
				return nil, err
			}
			reasoningEffort = ""
		}
	}

	if err := store.Set(agentName, role, state.RoleDefault{
		Model:           model,
		ReasoningEffort: reasoningEffort,
	}); err != nil {
		return nil, err
	}
	return map[string]string{"agent": agentName, "role": role, "model": model, "reasoning_effort": reasoningEffort}, nil
}

func (s *Server) mutateQuestAdd(payload mutationPayload) (any, error) {
	content, err := requiredValue("content", firstNonEmpty(payload.Content, payload.Body, payload.Message))
	if err != nil {
		return nil, err
	}
	projectID, projectPath, projectName, err := questProjectFromPayload(payload)
	if err != nil {
		return nil, err
	}
	quest, err := state.UpsertQuestAt(s.mutationStore().Root(), state.Quest{
		ID:          strings.TrimSpace(firstNonEmpty(payload.QuestID, payload.ID)),
		Content:     content,
		ProjectID:   projectID,
		ProjectPath: projectPath,
		ProjectName: projectName,
		SessionID:   strings.TrimSpace(payload.SessionID),
	})
	if err != nil {
		return nil, err
	}
	return quest, nil
}

func (s *Server) mutateQuestEdit(payload mutationPayload) (any, error) {
	id, err := requiredFirst("quest_id", payload.QuestID, payload.ID, payload.TargetID)
	if err != nil {
		return nil, err
	}
	quests, err := state.LoadQuestsAt(s.mutationStore().Root())
	if err != nil {
		return nil, err
	}
	var quest state.Quest
	found := false
	for _, item := range quests {
		if item.ID == id {
			quest = item
			found = true
			break
		}
	}
	if !found {
		return nil, fmt.Errorf("quest %q not found", id)
	}
	if content := firstNonEmpty(payload.Content, payload.Body, payload.Message); strings.TrimSpace(content) != "" {
		quest.Content = content
	}
	if mutationTruthy(payload.ProjectChanged) ||
		strings.TrimSpace(payload.ProjectID) != "" ||
		strings.TrimSpace(payload.ProjectPath) != "" ||
		strings.TrimSpace(payload.ProjectName) != "" {
		quest.ProjectID, quest.ProjectPath, quest.ProjectName, err = questProjectFromPayload(payload)
		if err != nil {
			return nil, err
		}
	}
	saved, err := state.UpsertQuestAt(s.mutationStore().Root(), quest)
	if err != nil {
		return nil, err
	}
	return saved, nil
}

// questProjectFromPayload takes the project the request names. A path sent without an id (a path typed
// in the app) resolves to the id and name `quest add --project` would give it.
func questProjectFromPayload(payload mutationPayload) (id, path, name string, err error) {
	id = strings.TrimSpace(payload.ProjectID)
	path = strings.TrimSpace(payload.ProjectPath)
	name = strings.TrimSpace(payload.ProjectName)
	if id != "" || path == "" {
		return id, path, name, nil
	}
	// serve's working directory isn't the user's, so a relative path would resolve against the wrong place.
	if !filepath.IsAbs(state.ExpandHome(path)) {
		return "", "", "", fmt.Errorf("project path must be absolute: %s", path)
	}
	return state.ResolveQuestProject(path, true)
}

func (s *Server) mutateQuestDelete(payload mutationPayload) (any, error) {
	id, err := requiredFirst("quest_id", payload.QuestID, payload.ID, payload.TargetID)
	if err != nil {
		return nil, err
	}
	removed, err := state.RemoveQuestAt(s.mutationStore().Root(), id)
	if err != nil {
		return nil, err
	}
	if !removed {
		return nil, fmt.Errorf("quest %q not found", id)
	}
	return map[string]any{"quest_id": id, "deleted": true}, nil
}

func (s *Server) mutateArtifactDelete(payload mutationPayload) (any, error) {
	path, err := requiredValue("path", payload.Path)
	if err != nil {
		return nil, err
	}
	root := s.mutationStore().Root()
	sessionID := strings.TrimSpace(payload.SessionID)
	var removed bool
	if sessionID == "" {
		removed, err = state.RemoveArtifactGlobal(root, path)
	} else {
		removed, err = state.RemoveArtifactAt(root, sessionID, path)
	}
	if err != nil {
		return nil, err
	}
	if !removed {
		return nil, fmt.Errorf("artifact %q not found", path)
	}
	return map[string]any{"path": path, "deleted": true}, nil
}

func (s *Server) mutationStore() *state.Store {
	if s != nil && s.Snapshotter != nil && s.Snapshotter.store != nil {
		return s.Snapshotter.store
	}
	return state.OpenStore(state.StateRoot())
}

func mutationDisplayColor(color string) (string, error) {
	color = strings.ToLower(strings.TrimSpace(color))
	if color == "" {
		return "", nil
	}
	if state.IsDisplayColor(color) {
		return color, nil
	}
	return "", fmt.Errorf("invalid color %q (want one of %s, or empty to clear)", color, strings.Join(state.DisplayColorOptions(), ", "))
}

func (s *Server) runCommandJSON(ctx context.Context, args []string, stdin []byte) (any, error) {
	for _, arg := range args {
		if strings.TrimSpace(arg) == "" {
			return nil, fmt.Errorf("mutation command argument is empty")
		}
	}
	runner := s.MutationRunner
	if runner == nil {
		runner = selfMutationCommandRunner{}
	}
	out, err := runner.RunMutationCommand(ctx, args, stdin)
	if err != nil {
		return nil, err
	}
	out = bytes.TrimSpace(out)
	if len(out) == 0 {
		return map[string]any{"ok": true}, nil
	}
	var decoded any
	dec := json.NewDecoder(bytes.NewReader(out))
	dec.UseNumber()
	if err := dec.Decode(&decoded); err != nil {
		return map[string]any{"output": string(out)}, nil
	}
	return decoded, nil
}

func requiredValue(name, value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%s is required", name)
	}
	return value, nil
}

func requiredFirst(name string, values ...string) (string, error) {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed, nil
		}
	}
	return "", fmt.Errorf("%s is required", name)
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func mutationTruthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "t", "yes", "y", "master":
		return true
	default:
		return false
	}
}
