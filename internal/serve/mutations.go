//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
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
	Status    string          `json:"status"`
	Action    string          `json:"action"`
	Anchor    json.RawMessage `json:"anchor"`
	Body      string          `json:"body"`
	Message   string          `json:"message"`
	Title     string          `json:"title"`
	Cwd       string          `json:"cwd"`
	Agent     string          `json:"agent"`
	Primary   string          `json:"primary"`
	Prompt    string          `json:"prompt"`
	Extra     map[string]any  `json:"-"`
	raw       map[string]json.RawMessage
}

func (s *Server) writeMutationResponse(ctx context.Context, enc *json.Encoder, req Request) error {
	data, err := s.mutate(ctx, req)
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
	switch method {
	case "quest.gate_toggle":
		return s.mutateQuestGateToggle(req, payload)
	case "quest.comment_add":
		return s.mutateQuestCommentAdd(req, payload)
	case "quest.status":
		return s.mutateQuestStatus(ctx, req, payload)
	case "relay":
		workerID, err := requiredFirst("worker_id", payload.WorkerID, payload.TargetID, payload.SessionID, payload.ID)
		if err != nil {
			return nil, err
		}
		message, err := requiredValue("message", payload.Message)
		if err != nil {
			return nil, err
		}
		return s.runCommandJSON(ctx, []string{"relay", workerID, "--message-file", "-"}, []byte(message))
	case "broadcast":
		args := []string{"broadcast"}
		if masterID := strings.TrimSpace(payload.MasterID); masterID != "" {
			args = append(args, masterID)
		}
		args = append(args, "--message-file", "-")
		message, err := requiredValue("message", payload.Message)
		if err != nil {
			return nil, err
		}
		return s.runCommandJSON(ctx, args, []byte(message))
	case "delete":
		sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
		if err != nil {
			return nil, err
		}
		return s.runCommandJSON(ctx, []string{"delete", sessionID}, nil)
	case "continue":
		sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
		if err != nil {
			return nil, err
		}
		return s.runCommandJSON(ctx, []string{"continue", sessionID}, nil)
	case "attach_to_quest":
		sessionID, err := requiredFirst("session_id", payload.SessionID, payload.ID)
		if err != nil {
			return nil, err
		}
		questID, err := requiredFirst("quest_id", payload.QuestID, payload.Quest, req.QuestID)
		if err != nil {
			return nil, err
		}
		return s.runCommandJSON(ctx, []string{"session", "attach", sessionID, "--quest", questID}, nil)
	case "spawn":
		return s.mutateSpawn(ctx, req, payload)
	case "switch":
		return s.mutateSwitch(ctx, payload)
	default:
		return nil, fmt.Errorf("unknown mutation method %q", req.Method)
	}
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
		payload.raw = map[string]json.RawMessage{}
		return payload, nil
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return mutationPayload{}, fmt.Errorf("decode mutation data: %w", err)
	}
	_ = json.Unmarshal(raw, &payload.raw)
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
	store := quest.DefaultStore()
	q, err := store.Load(questID)
	if err != nil {
		return nil, err
	}
	checked, err := quest.ToggleGate(q, gateName)
	if err != nil {
		return nil, err
	}
	if err := store.Save(q); err != nil {
		return nil, err
	}
	return map[string]any{"quest_id": q.ID, "gate": gateName, "checked": checked}, nil
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
	store := quest.DefaultStore()
	q, err := store.Load(questID)
	if err != nil {
		return nil, err
	}
	comment, err := quest.AddComment(q, anchor, mutationAuthorName(), payload.Body, time.Now().UTC())
	if err != nil {
		return nil, fmt.Errorf("comment add refused: %w", err)
	}
	if err := store.Save(q); err != nil {
		return nil, err
	}
	return map[string]any{
		"quest_id":   q.ID,
		"comment_id": comment.ID,
		"anchor":     comment.Anchor,
		"status":     comment.Status,
		"comment":    comment,
	}, nil
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

func (s *Server) mutateSpawn(ctx context.Context, req Request, payload mutationPayload) (any, error) {
	args := []string{"spawn"}
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
	if masterID := strings.TrimSpace(payload.MasterID); masterID != "" {
		args = append(args, masterID)
	}
	if title := strings.TrimSpace(firstNonEmpty(payload.Title, payload.Name)); title != "" {
		args = append(args, title)
	}
	return s.runCommandJSON(ctx, args, stdin)
}

func (s *Server) mutateSwitch(ctx context.Context, payload mutationPayload) (any, error) {
	sessionID, err := requiredFirst("session_id", payload.SessionID, payload.TargetID, payload.ID)
	if err != nil {
		return nil, err
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
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func mutationAuthorName() string {
	for _, key := range []string{"QUESTMASTER_AUTHOR", "GIT_AUTHOR_NAME", "USER"} {
		if v := strings.TrimSpace(os.Getenv(key)); v != "" {
			return v
		}
	}
	return ""
}
