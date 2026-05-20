package cmd

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

// HookRunner is the dependency surface used by the hook subcommand. It
// exists for testability: tests can substitute fakes for the file-system
// side effects without touching real disks. Production wiring goes
// through the default implementation backed by internal/state.
type HookRunner struct {
	// Now returns the current time; tests override for deterministic
	// LastEvent fields.
	Now func() time.Time

	// LoadTranscriptTail returns up to ~4 KiB from the end of a Claude
	// transcript_path file. Returns (nil, nil) if the file is missing or
	// unreadable — the Stop hook must never fail because the transcript
	// file is gone (PLAN.md Risk #8).
	LoadTranscriptTail func(path string) ([]byte, error)

	// Update applies a tracker-style locked read-modify-write to the
	// session's state.json. Returning false from mutate skips the disk
	// write (used for the hot-path conditional flush).
	Update func(sessionID string, mutate func(*state.SessionState) bool) error

	// AppendEvent appends one line to state.jsonl. Best-effort: a write
	// failure here is logged but does not fail the hook.
	AppendEvent func(sessionID string, ev state.StateEvent) error
}

// defaultHookRunner wires HookRunner to the real internal/state package.
func defaultHookRunner() *HookRunner {
	return &HookRunner{
		Now:                time.Now,
		LoadTranscriptTail: loadTranscriptTail,
		Update:             state.UpdateSessionState,
		AppendEvent:        state.AppendStateEvent,
	}
}

// hookOptions holds parsed CLI inputs.
type hookOptions struct {
	agent   string
	action  string
	session string
	stdin   []byte
}

// newHookCmd builds `party-cli hook <agent> <action>`. The tmux/state
// args mirror other subcommand factories for consistency; this hot path
// must never call methods that scan the state root (e.g. DiscoverSessions).
func newHookCmd(_ /* store */ interface{}, _ /* client */ *tmux.Client) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{
		Use:   "hook <agent> <action>",
		Short: "Internal: process an agent hook event (called by installed shell scripts)",
		Long: "party-cli hook is the entry point for agent-native hooks. It is\n" +
			"invoked by the small shell scripts written by `party-cli hooks install`\n" +
			"and writes the per-session state.json / state.jsonl.\n\n" +
			"Hook failures must never propagate to the agent: this command always\n" +
			"exits 0 (any internal error is logged to stderr).",
		Args:          cobra.ExactArgs(2),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts := hookOptions{agent: args[0], action: args[1], session: sessionFlag}
			if data, err := readStdinNonBlocking(cmd.InOrStdin()); err == nil {
				opts.stdin = data
			}
			runHook(defaultHookRunner(), opts, cmd.ErrOrStderr())
			return nil
		},
	}
	cmd.Flags().StringVar(&sessionFlag, "session", "", "session ID (defaults to $PARTY_SESSION)")
	return cmd
}

// runHook is the testable core. It never returns an error; all failures
// are logged to stderr and otherwise swallowed so installed shell scripts
// can `exec` this binary with no agent-visible side effect.
func runHook(r *HookRunner, opts hookOptions, stderr io.Writer) {
	id := opts.session
	if id == "" {
		id = os.Getenv("PARTY_SESSION")
	}
	if id == "" {
		return
	}
	if !state.IsValidPartyID(id) {
		fmt.Fprintf(stderr, "party-cli hook: invalid PARTY_SESSION %q\n", id)
		return
	}

	switch opts.agent {
	case "claude":
		handleClaude(r, id, opts, stderr)
	case "codex":
		handleCodex(r, id, opts, stderr)
	case "pi":
		handlePi(r, id, opts, stderr)
	default:
		fmt.Fprintf(stderr, "party-cli hook: unknown agent %q\n", opts.agent)
	}
}

// readStdinNonBlocking reads up to 64 KiB from stdin if it has any data.
// If stdin is a TTY (no piped payload) we don't block: agents always pipe
// JSON or close the stream, so a quick ReadAll is safe in practice.
func readStdinNonBlocking(r io.Reader) ([]byte, error) {
	if r == nil {
		return nil, nil
	}
	const maxBytes = 64 * 1024
	return io.ReadAll(io.LimitReader(r, maxBytes))
}

// ---------------------------------------------------------------------
// Claude
// ---------------------------------------------------------------------

// claudePayload mirrors the fields the Claude hook payload exposes. The
// shape is intentionally tolerant: every field is optional, unknown
// fields are ignored, and missing fields use zero values. Schema drift
// in upstream Claude can't break hook ingestion — see PLAN.md Risk #1.
type claudePayload struct {
	AgentID        string                 `json:"agent_id"`
	ToolName       string                 `json:"tool_name"`
	ToolInput      map[string]interface{} `json:"tool_input"`
	Prompt         string                 `json:"prompt"`
	Message        string                 `json:"message"`
	Text           string                 `json:"text"`
	TranscriptPath string                 `json:"transcript_path"`
	Result         string                 `json:"result"`
}

func decodeClaude(data []byte) claudePayload {
	var p claudePayload
	if len(data) == 0 {
		return p
	}
	// Errors are tolerated — a bad payload still produces a useful event
	// log line (action+timestamp) and the renderer falls back to
	// last-known state.
	_ = json.Unmarshal(data, &p)
	return p
}

func handleClaude(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer) {
	payload := decodeClaude(opts.stdin)
	now := r.Now().UTC()
	isSubagent := payload.AgentID != ""

	ev := state.StateEvent{
		Ts:     now,
		Agent:  "claude",
		Role:   "primary",
		Action: opts.action,
	}

	// Compute the desired pane mutation. Subagent suppression is applied
	// per PLAN.md "Subagent rule" — Claude-specific because only Claude
	// carries an agent_id discriminator.
	var (
		setState    string // empty → do not change State
		setActivity string
		setTool     string
		clearTool   bool
		lastKind    string
		// suppressStateForSubagent controls whether the subagent rule
		// applies to this action. tool_start / tool_end on a subagent
		// still update Activity (so the renderer can show what the
		// subagent is doing) but never flip the parent State.
		suppressStateForSubagent bool
	)

	switch opts.action {
	case "starting":
		setState = "starting"
		setActivity = "starting…"
		lastKind = "SessionStart"
	case "working":
		// UserPromptSubmit — turn-start state per PLAN.md lines 147–156.
		setState = "working"
		setActivity = "You: " + truncatePromptLine(payload.Prompt)
		lastKind = "UserPromptSubmit"
		suppressStateForSubagent = true
	case "tool_start":
		setState = "working"
		setActivity = activityForTool(payload)
		setTool = payload.ToolName
		lastKind = "PreToolUse"
		suppressStateForSubagent = true
	case "tool_end":
		setState = "working"
		clearTool = true
		lastKind = "PostToolUse"
		suppressStateForSubagent = true
		// Activity stays as the most recent PreToolUse snippet (PLAN.md
		// line 137: PostToolUse does not clobber the tool snippet).
	case "done":
		if !isSubagent {
			setState = "done"
		}
		if tail, err := r.LoadTranscriptTail(payload.TranscriptPath); err == nil && len(tail) > 0 {
			if snippet := saidSnippet(tail); snippet != "" {
				setActivity = "Said: " + snippet
			}
		}
		lastKind = "Stop"
	case "subagent_stop":
		// SubagentStop: Activity only, never mutate parent State per
		// PLAN.md lines 140 + 155.
		result := strings.TrimSpace(payload.Result)
		if result == "" {
			result = strings.TrimSpace(payload.Text)
		}
		if result != "" {
			setActivity = "Subagent: " + truncatePromptLine(result)
		}
		lastKind = "SubagentStop"
	case "blocked":
		setState = "blocked"
		msg := payload.Message
		if msg == "" {
			msg = payload.Text
		}
		setActivity = "Notification: " + truncatePromptLine(msg)
		lastKind = "Notification"
	case "stopped":
		setState = "stopped"
		lastKind = "SessionEnd"
	default:
		fmt.Fprintf(stderr, "party-cli hook claude: unknown action %q\n", opts.action)
		return
	}

	// Subagent suppression: drop the State mutation while preserving
	// Activity/Tool/LastKind updates so the renderer still gets useful
	// snippets out of subagent tool calls.
	if isSubagent && suppressStateForSubagent {
		setState = ""
	}
	if isSubagent && opts.action == "done" {
		// Suppress both State and Activity for a subagent Stop — the
		// parent pane shouldn't show "Said: <subagent message>" as if
		// the parent just spoke. The SubagentStop event carries the
		// actual subagent snippet.
		setState = ""
		setActivity = ""
	}

	ev.State = setState
	ev.Activity = setActivity
	ev.Tool = setTool
	ev.Kind = lastKind

	if err := r.AppendEvent(sessionID, ev); err != nil {
		fmt.Fprintf(stderr, "party-cli hook claude: append event: %v\n", err)
	}

	mutateErr := r.Update(sessionID, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "claude"}
		}
		// Snapshot the renderer-visible fields BEFORE mutation so we can
		// detect whether anything that affects the dot/snippet
		// rendering actually changed. PLAN.md line 122 lists the five
		// fields the renderer reads. Other field changes (e.g. Seq)
		// don't require a flush.
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent                       time.Time
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent}

		if setState != "" {
			pane.State = setState
		}
		if setActivity != "" {
			pane.Activity = setActivity
		}
		if setTool != "" {
			pane.Tool = setTool
		} else if clearTool {
			pane.Tool = ""
		}
		if lastKind != "" {
			pane.LastKind = lastKind
		}
		pane.LastEvent = now
		pane.Seq = now.UnixNano()
		pane.Agent = "claude"
		pane.Role = role
		ss.Panes[role] = pane

		// Conditional flush. Per PLAN.md line 122, we re-write state.json
		// whenever any of {State, Activity, Tool, LastKind, LastEvent}
		// changed. LastEvent updates on every event so this practically
		// always flushes — that's the intended behaviour. The skip
		// exists so a hypothetical no-op event (same kind, identical
		// time) doesn't bump file mtime needlessly.
		if pane.State == prev.State &&
			pane.Activity == prev.Activity &&
			pane.Tool == prev.Tool &&
			pane.LastKind == prev.LastKind &&
			pane.LastEvent.Equal(prev.LastEvent) {
			return false
		}
		return true
	})
	if mutateErr != nil {
		fmt.Fprintf(stderr, "party-cli hook claude: update state: %v\n", mutateErr)
	}
}

// activityForTool formats the Activity field for a PreToolUse event.
// Falls back to "Tool: <name>" when the tool isn't one of the rich-format
// cases listed in PLAN.md lines 132–137.
func activityForTool(p claudePayload) string {
	name := p.ToolName
	in := p.ToolInput
	get := func(k string) string {
		if v, ok := in[k].(string); ok {
			return v
		}
		return ""
	}
	switch name {
	case "Edit", "Write", "MultiEdit", "NotebookEdit":
		return "Edit " + truncatePath(get("file_path"))
	case "Read":
		return "Read " + truncatePath(get("file_path"))
	case "Bash":
		return "Bash: " + truncatePromptLine(get("command"))
	case "Task":
		return "Agent: " + truncatePromptLine(get("description"))
	case "Grep", "Glob":
		return "Search: " + truncatePromptLine(get("pattern"))
	case "":
		return ""
	default:
		return name
	}
}

// truncatePromptLine applies PLAN.md's truncation rules: first line only,
// strip leading `[A-Z_]+=\S+` env-var assignments, max 60 chars.
func truncatePromptLine(s string) string {
	if s == "" {
		return ""
	}
	if nl := strings.IndexByte(s, '\n'); nl >= 0 {
		s = s[:nl]
	}
	s = stripLeadingEnvAssignments(s)
	if len(s) > 60 {
		s = s[:60]
	}
	return s
}

// stripLeadingEnvAssignments removes shell-style `KEY=value` prefixes
// from a command line so Bash invocations like
// `OPENAI_API_KEY=sk-... do-the-thing` don't leak into Activity.
func stripLeadingEnvAssignments(s string) string {
	for {
		s = strings.TrimLeft(s, " \t")
		eq := strings.IndexByte(s, '=')
		if eq <= 0 {
			return s
		}
		key := s[:eq]
		if !looksLikeEnvKey(key) {
			return s
		}
		// Drop everything up to and including the first whitespace.
		rest := s[eq+1:]
		ws := strings.IndexAny(rest, " \t")
		if ws < 0 {
			return ""
		}
		s = rest[ws+1:]
	}
}

func looksLikeEnvKey(k string) bool {
	if k == "" {
		return false
	}
	for _, c := range k {
		if c == '_' || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			continue
		}
		return false
	}
	return true
}

func truncatePath(p string) string {
	if p == "" {
		return ""
	}
	base := filepath.Base(p)
	if len(base) > 60 {
		base = base[:60]
	}
	return base
}

// loadTranscriptTail reads up to ~4 KiB from the end of the transcript
// file. Per PLAN.md Risk #8: missing or unreadable transcripts must not
// fail the hook. Returns (nil, nil) on any error.
func loadTranscriptTail(path string) ([]byte, error) {
	if path == "" {
		return nil, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, nil
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil {
		return nil, nil
	}
	const tailSize = 4 * 1024
	offset := info.Size() - tailSize
	if offset < 0 {
		offset = 0
	}
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return nil, nil
	}
	data, err := io.ReadAll(io.LimitReader(f, tailSize))
	if err != nil {
		return nil, nil
	}
	return data, nil
}

// saidSnippet extracts the most recent assistant text from a Claude
// transcript tail. The transcript is JSONL; we walk lines in reverse
// looking for the first assistant message with non-empty text content.
// Best-effort: returns "" rather than failing on a malformed line.
func saidSnippet(tail []byte) string {
	lines := strings.Split(string(tail), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		raw := strings.TrimSpace(lines[i])
		if raw == "" {
			continue
		}
		var rec struct {
			Type    string `json:"type"`
			Role    string `json:"role"`
			Message struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			} `json:"message"`
			Text string `json:"text"`
		}
		if err := json.Unmarshal([]byte(raw), &rec); err != nil {
			continue
		}
		role := rec.Role
		if role == "" {
			role = rec.Message.Role
		}
		if role != "assistant" {
			continue
		}
		text := extractAssistantText(rec.Message.Content)
		if text == "" {
			text = rec.Text
		}
		if text == "" {
			continue
		}
		return truncatePromptLine(text)
	}
	return ""
}

// extractAssistantText pulls the first text block out of the Claude
// content array. The content field can be a string (legacy) or an array
// of {type: "text", text: "..."} / {type: "tool_use", ...} blocks.
func extractAssistantText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var arr []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &arr); err == nil {
		for _, b := range arr {
			if b.Type == "text" && b.Text != "" {
				return b.Text
			}
		}
	}
	return ""
}

// ---------------------------------------------------------------------
// Codex / Pi stubs — full handlers land in PR-B / PR-C.
// ---------------------------------------------------------------------

func handleCodex(_ *HookRunner, _ string, _ hookOptions, stderr io.Writer) {
	fmt.Fprintln(stderr, "party-cli hook codex: not yet implemented — see PR-B / PR-C")
}

func handlePi(_ *HookRunner, _ string, _ hookOptions, stderr io.Writer) {
	fmt.Fprintln(stderr, "party-cli hook pi: not yet implemented — see PR-B / PR-C")
}

// ErrHookSubagentSuppressed is exported for tests that want to assert
// the subagent suppression behaviour from outside the package.
var ErrHookSubagentSuppressed = errors.New("hook event suppressed by subagent rule")
