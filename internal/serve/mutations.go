//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"

	qlifecycle "github.com/alexivison/questmaster/internal/quests/lifecycle"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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
	ID        string          `json:"id"`
	SessionID string          `json:"session_id"`
	WorkerID  string          `json:"worker_id"`
	TargetID  string          `json:"target_id"`
	MasterID  string          `json:"master_id"`
	QuestID   string          `json:"quest_id"`
	Quest     string          `json:"quest"`
	Gate      string          `json:"gate"`
	GateName  string          `json:"gate_name"`
	Name      string          `json:"name"`
	CommentID string          `json:"comment_id"`
	Status    string          `json:"status"`
	Action    string          `json:"action"`
	Anchor    json.RawMessage `json:"anchor"`
	Body      string          `json:"body"`
	Message   string          `json:"message"`
	Scope     string          `json:"scope"`
	Repo      string          `json:"repo"`
	RepoID    string          `json:"repo_identity"`
	Title     string          `json:"title"`
	Cwd       string          `json:"cwd"`
	Agent     string          `json:"agent"`
	Primary   string          `json:"primary"`
	Color     string          `json:"color"`
	Master    string          `json:"master"`
	Prompt    string          `json:"prompt"`
	Extra     map[string]any  `json:"-"`
}

type mutationHandler func(*Server, context.Context, Request, mutationPayload) (any, error)

// Mutation execution has three deliberately separate models:
// 1. in-process quest/display mutations that call core packages directly,
// 2. re-execed qm commands for session lifecycle and messaging mutations,
// 3. direct tmux calls for focus/switch behavior that must not spawn qm.
// New methods should pick one model explicitly instead of crossing layers.
var mutationRegistry = map[string]mutationHandler{
	"quest.gate_toggle": func(s *Server, _ context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestGateToggle(req, payload)
	},
	"quest.comment_add": func(s *Server, _ context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestCommentAdd(req, payload)
	},
	"quest.comment_edit": func(s *Server, _ context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestCommentEdit(req, payload)
	},
	"quest.comment_delete": func(s *Server, _ context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestCommentDelete(req, payload)
	},
	"quest.comment_resolve": func(s *Server, _ context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestCommentResolve(req, payload)
	},
	"quest.status": func(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateQuestStatus(ctx, req, payload)
	},
	"quest.delete":    mutateQuestDelete,
	"relay":           mutateRelay,
	"broadcast":       mutateBroadcast,
	"delete":          mutateDelete,
	"continue":        mutateContinue,
	"attach_to_quest": mutateAttachToQuest,
	"spawn": func(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateSpawn(ctx, req, payload)
	},
	"start": func(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
		return s.mutateStart(ctx, req, payload)
	},
	"switch": func(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateSwitch(ctx, payload)
	},
	"recolor": func(s *Server, _ context.Context, _ Request, payload mutationPayload) (any, error) {
		return s.mutateRecolor(payload)
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

func (s *Server) writeMutationResponse(ctx context.Context, enc *json.Encoder, req Request) error {
	mutationCtx := ctx
	cancel := func() {}
	if mutationOperationTimeout > 0 {
		mutationCtx, cancel = context.WithTimeout(ctx, mutationOperationTimeout)
	}
	defer cancel()
	data, err := s.mutate(mutationCtx, req)
	if err != nil {
		return writeEnvelope(enc, errorEnvelope(req.ID, err))
	}
	return writeEnvelope(enc, Envelope{Type: "response", ID: req.ID, OK: boolPtr(true), Topic: req.Method, Data: data})
}

func (s *Server) mutate(ctx context.Context, req Request) (any, error) {
	method := canonicalMutationMethod(req.Method)
	payload, err := decodeMutationPayload(req.Data)
	if err != nil {
		return nil, err
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

func (s *Server) mutateQuestGateToggle(req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	gateName, err := requiredFirst("gate", payload.Gate, payload.GateName, payload.Name)
	if err != nil {
		return nil, err
	}
	return qlifecycle.ToggleGate(quest.DefaultStore(), questID, gateName)
}

func (s *Server) mutateQuestCommentAdd(req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	anchor, err := mutationCommentAnchor(payload)
	if err != nil {
		return nil, err
	}
	return qlifecycle.AddComment(quest.DefaultStore(), questID, anchor, mutationAuthorName(), payload.Body, time.Now().UTC())
}

func (s *Server) mutateQuestCommentEdit(req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	commentID, err := requiredFirst("comment_id", payload.CommentID, payload.ID)
	if err != nil {
		return nil, err
	}
	body, err := requiredValue("body", payload.Body)
	if err != nil {
		return nil, err
	}
	return qlifecycle.UpdateCommentBody(quest.DefaultStore(), questID, commentID, body)
}

func (s *Server) mutateQuestCommentDelete(req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	commentID, err := requiredFirst("comment_id", payload.CommentID, payload.ID)
	if err != nil {
		return nil, err
	}
	return qlifecycle.DeleteComment(quest.DefaultStore(), questID, commentID)
}

func (s *Server) mutateQuestCommentResolve(req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	commentID, err := requiredFirst("comment_id", payload.CommentID, payload.ID)
	if err != nil {
		return nil, err
	}
	return qlifecycle.ResolveComment(quest.DefaultStore(), questID, commentID, time.Now().UTC())
}

func mutationCommentAnchor(payload mutationPayload) (quest.CommentAnchor, error) {
	if len(bytes.TrimSpace(payload.Anchor)) == 0 {
		return quest.CommentAnchor{Kind: quest.CommentAnchorQuest}, nil
	}
	var raw string
	if err := json.Unmarshal(payload.Anchor, &raw); err == nil {
		return quest.ParseCommentAnchor(raw)
	}
	var anchor quest.CommentAnchor
	if err := json.Unmarshal(payload.Anchor, &anchor); err != nil {
		return quest.CommentAnchor{}, fmt.Errorf("decode comment anchor: %w", err)
	}
	return anchor, nil
}

func (s *Server) mutateQuestStatus(ctx context.Context, req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	target, err := mutationStatus(payload)
	if err != nil {
		return nil, err
	}
	return qlifecycle.SetStatus(ctx, quest.DefaultStore(), state.OpenStore(state.StateRoot()), questID, target)
}

func mutationStatus(payload mutationPayload) (quest.Status, error) {
	value := strings.TrimSpace(payload.Status)
	if value == "" {
		value = strings.TrimSpace(payload.Action)
	}
	switch value {
	case "approve", "active":
		return quest.StatusActive, nil
	case "done":
		return quest.StatusDone, nil
	case "withdraw", "wip":
		return quest.StatusWIP, nil
	default:
		return "", fmt.Errorf("status is required (want approve, done, withdraw, active, wip)")
	}
}

func mutateRelay(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	workerID, err := requiredFirst("worker_id", payload.WorkerID, payload.TargetID, payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	message, err := requiredValue("message", payload.Message)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"relay", workerID, "--message-file", "-"}, []byte(message))
}

func mutateBroadcast(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	args := []string{"broadcast", "--message-file", "-"}
	if masterID := strings.TrimSpace(payload.MasterID); masterID != "" {
		args = append(args, "--", masterID)
	}
	message, err := requiredValue("message", payload.Message)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, args, []byte(message))
}

func mutateDelete(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"delete", sessionID}, nil)
}

func mutateQuestDelete(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, payload.ID, req.QuestID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"quest", "delete", questID}, nil)
}

func mutateContinue(s *Server, ctx context.Context, _ Request, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"continue", sessionID}, nil)
}

func mutateAttachToQuest(s *Server, ctx context.Context, req Request, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
	if err != nil {
		return nil, err
	}
	questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
	if err != nil {
		return nil, err
	}
	return s.runCommandJSON(ctx, []string{"session", "attach", sessionID, "--quest", questID}, nil)
}

func (s *Server) mutateSpawn(ctx context.Context, req Request, payload mutationPayload) (any, error) {
	args := []string{"spawn", "--from-app"}
	if cwd := strings.TrimSpace(payload.Cwd); cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	if primary := strings.TrimSpace(firstNonEmpty(payload.Primary, payload.Agent)); primary != "" {
		args = append(args, "--primary", primary)
	}
	if questID := strings.TrimSpace(firstNonEmpty(payload.QuestID, payload.Quest, req.QuestID)); questID != "" {
		args = append(args, "--quest", questID)
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
	if cwd := strings.TrimSpace(payload.Cwd); cwd != "" {
		args = append(args, "--cwd", cwd)
	}
	if primary := strings.TrimSpace(firstNonEmpty(payload.Primary, payload.Agent)); primary != "" {
		args = append(args, "--primary", primary)
	}
	if color := strings.TrimSpace(payload.Color); color != "" {
		args = append(args, "--color", color)
	}
	if questID := strings.TrimSpace(firstNonEmpty(payload.QuestID, payload.Quest, req.QuestID)); questID != "" {
		args = append(args, "--quest", questID)
	}
	if mutationTruthy(payload.Master) {
		args = append(args, "--master")
	}
	var stdin []byte
	if strings.TrimSpace(payload.Prompt) != "" {
		args = append(args, "--prompt-file", "-")
		stdin = []byte(payload.Prompt)
	}
	if title := strings.TrimSpace(firstNonEmpty(payload.Title, payload.Name)); title != "" {
		args = append(args, "--", title)
	}
	return s.runCommandJSON(ctx, args, stdin)
}

func (s *Server) mutateSwitch(ctx context.Context, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.TargetID, payload.ID)
	if err != nil {
		return nil, err
	}
	if !state.IsValidSessionID(sessionID) {
		return nil, fmt.Errorf("invalid session_id %q", sessionID)
	}
	client := s.TmuxClient
	if client == nil {
		client = tmux.NewExecClient()
	}
	if err := client.SwitchClientWithFallback(ctx, sessionID); err != nil {
		return nil, err
	}
	return map[string]any{"session_id": sessionID, "switched": true}, nil
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

func mutationAuthorName() string {
	for _, key := range []string{"QUESTMASTER_AUTHOR", "GIT_AUTHOR_NAME", "USER"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
	}
	return ""
}
