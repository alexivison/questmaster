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
// Codex
// ---------------------------------------------------------------------

// codexPayload mirrors the current Codex hook command input fields. The
// parser is tolerant for the same reason as Claude: Codex hook schemas are
// still moving, so missing fields should degrade the Activity snippet
// rather than break the state transition.
type codexPayload struct {
	ToolName             string                 `json:"tool_name"`
	ToolInput            map[string]interface{} `json:"tool_input"`
	Prompt               string                 `json:"prompt"`
	TranscriptPath       string                 `json:"transcript_path"`
	LastAssistantMessage string                 `json:"last_assistant_message"`
}

func decodeCodex(data []byte) codexPayload {
	var p codexPayload
	if len(data) == 0 {
		return p
	}
	_ = json.Unmarshal(data, &p)
	return p
}

func handleCodex(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer) {
	payload := decodeCodex(opts.stdin)
	now := r.Now().UTC()

	ev := state.StateEvent{
		Ts:     now,
		Agent:  "codex",
		Role:   "primary",
		Action: opts.action,
	}

	var (
		setState    string
		setActivity string
		setTool     string
		clearTool   bool
		lastKind    string
	)

	switch opts.action {
	case "starting":
		setState = "starting"
		setActivity = "starting…"
		lastKind = "SessionStart"
	case "working":
		setState = "working"
		setActivity = "You: " + truncatePromptLine(payload.Prompt)
		lastKind = "UserPromptSubmit"
	case "tool_start":
		setState = "working"
		setActivity = activityForCodexTool(payload)
		setTool = payload.ToolName
		lastKind = "PreToolUse"
	case "tool_end":
		setState = "working"
		clearTool = true
		lastKind = "PostToolUse"
	case "done":
		setState = "done"
		if payload.LastAssistantMessage != "" {
			setActivity = "Said: " + truncatePromptLine(payload.LastAssistantMessage)
		} else if tail, err := r.LoadTranscriptTail(payload.TranscriptPath); err == nil && len(tail) > 0 {
			if snippet := saidSnippet(tail); snippet != "" {
				setActivity = "Said: " + snippet
			}
		}
		lastKind = "Stop"
	default:
		fmt.Fprintf(stderr, "party-cli hook codex: unknown action %q\n", opts.action)
		return
	}

	ev.State = setState
	ev.Activity = setActivity
	ev.Tool = setTool
	ev.Kind = lastKind

	if err := r.AppendEvent(sessionID, ev); err != nil {
		fmt.Fprintf(stderr, "party-cli hook codex: append event: %v\n", err)
	}

	mutateErr := r.Update(sessionID, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "codex"}
		}
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
		pane.Agent = "codex"
		pane.Role = role
		ss.Panes[role] = pane

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
		fmt.Fprintf(stderr, "party-cli hook codex: update state: %v\n", mutateErr)
	}
}

func activityForCodexTool(p codexPayload) string {
	name := p.ToolName
	in := p.ToolInput
	get := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := in[k].(string); ok {
				return v
			}
		}
		return ""
	}
	switch name {
	case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
		return "Edit " + truncatePath(get("file_path", "path"))
	case "Read":
		return "Read " + truncatePath(get("file_path", "path"))
	case "Bash", "Shell", "shell":
		return "Bash: " + truncatePromptLine(get("command", "cmd"))
	case "Task":
		return "Agent: " + truncatePromptLine(get("description", "prompt"))
	case "Grep", "Glob", "Search", "rg":
		return "Search: " + truncatePromptLine(get("pattern", "query"))
	case "":
		return ""
	default:
		return name
	}
}

// ---------------------------------------------------------------------
// Pi
// ---------------------------------------------------------------------

type piPayload struct {
	ID                    string                  `json:"id"`
	SessionID             string                  `json:"session_id"`
	PiSessionID           string                  `json:"pi_session_id"`
	SessionFile           string                  `json:"session_file"`
	Recent                []string                `json:"recent"`
	Snippet               string                  `json:"snippet"`
	Text                  string                  `json:"text"`
	Prompt                string                  `json:"prompt"`
	ToolName              string                  `json:"toolName"`
	ToolNameSnake         string                  `json:"tool_name"`
	Name                  string                  `json:"name"`
	Args                  interface{}             `json:"args"`
	Arguments             interface{}             `json:"arguments"`
	Input                 interface{}             `json:"input"`
	Tool                  piToolPayload           `json:"tool"`
	Message               interface{}             `json:"message"`
	Messages              []interface{}           `json:"messages"`
	AssistantMessageEvent piAssistantMessageEvent `json:"assistantMessageEvent"`
}

type piToolPayload struct {
	Name          string      `json:"name"`
	ToolName      string      `json:"toolName"`
	ToolNameSnake string      `json:"tool_name"`
	Summary       string      `json:"summary"`
	Args          interface{} `json:"args"`
	Arguments     interface{} `json:"arguments"`
	Input         interface{} `json:"input"`
}

type piAssistantMessageEvent struct {
	Type    string      `json:"type"`
	Delta   interface{} `json:"delta"`
	Content interface{} `json:"content"`
}

func decodePi(data []byte) piPayload {
	var p piPayload
	if len(data) == 0 {
		return p
	}
	_ = json.Unmarshal(data, &p)
	return p
}

func handlePi(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer) {
	payload := decodePi(opts.stdin)
	now := r.Now().UTC()
	lastKind := opts.action

	var (
		setState    string
		setActivity string
		setTool     string
		clearTool   bool
	)

	switch opts.action {
	case "session_start", "before_agent_start", "agent_start":
		setState = "starting"
		setActivity = piPromptActivity(payload)
		if setActivity == "" {
			setActivity = "starting…"
		}
	case "message_update":
		setState = "working"
		setActivity = "Replying…"
	case "message_end":
		setState = "working"
		setActivity = "Replying…"
	case "tool_execution_start":
		setState = "working"
		setTool = piToolName(payload)
		setActivity = piToolActivity(payload)
	case "tool_execution_end":
		setState = "working"
		clearTool = true
	case "agent_end":
		setState = "done"
		clearTool = true
		if text := piLastMessageText(payload); text != "" {
			setActivity = "Said: " + truncatePromptLine(text)
		}
	case "session_shutdown":
		setState = "stopped"
		clearTool = true
	default:
		fmt.Fprintf(stderr, "party-cli hook pi: unknown action %q\n", opts.action)
		return
	}

	recent, hasRecent := piRecentForAction(opts.action, payload)
	sessionFile := strings.TrimSpace(payload.SessionFile)
	piSessionID := strings.TrimSpace(payload.PiSessionID)

	ev := state.StateEvent{
		Ts:       now,
		Agent:    "pi",
		Role:     "primary",
		Action:   opts.action,
		State:    setState,
		Activity: setActivity,
		Tool:     setTool,
		Kind:     lastKind,
	}
	fields := map[string]interface{}{}
	if sessionFile != "" {
		fields["session_file"] = sessionFile
	}
	if piSessionID != "" {
		fields["pi_session_id"] = piSessionID
	}
	if hasRecent {
		fields["recent_count"] = len(recent)
	}
	if len(fields) > 0 {
		ev.Fields = fields
	}

	if err := r.AppendEvent(sessionID, ev); err != nil {
		fmt.Fprintf(stderr, "party-cli hook pi: append event: %v\n", err)
	}

	mutateErr := r.Update(sessionID, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "pi"}
		}
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent                       time.Time
			Recent                          []string
			SessionFile, PiSessionID        string
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.Recent, pane.SessionFile, pane.PiSessionID}

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
		if hasRecent {
			pane.Recent = recent
		}
		if sessionFile != "" {
			pane.SessionFile = sessionFile
		}
		if piSessionID != "" {
			pane.PiSessionID = piSessionID
		}
		pane.LastKind = lastKind
		pane.LastEvent = now
		pane.Seq = now.UnixNano()
		pane.Agent = "pi"
		pane.Role = role
		ss.Panes[role] = pane

		if pane.State == prev.State &&
			pane.Activity == prev.Activity &&
			pane.Tool == prev.Tool &&
			pane.LastKind == prev.LastKind &&
			pane.LastEvent.Equal(prev.LastEvent) &&
			stringSlicesEqual(pane.Recent, prev.Recent) &&
			pane.SessionFile == prev.SessionFile &&
			pane.PiSessionID == prev.PiSessionID {
			return false
		}
		return true
	})
	if mutateErr != nil {
		fmt.Fprintf(stderr, "party-cli hook pi: update state: %v\n", mutateErr)
	}
}

func piRecentForAction(action string, payload piPayload) ([]string, bool) {
	if payload.Recent != nil {
		return cleanPiRecent(payload.Recent), true
	}
	if action == "message_end" || action == "agent_end" {
		if text := piLastMessageText(payload); text != "" {
			return cleanPiRecent(strings.Split(text, "\n")), true
		}
	}
	return nil, false
}

func piPromptActivity(p piPayload) string {
	for _, prompt := range []string{p.Prompt, p.Text} {
		if strings.TrimSpace(prompt) != "" {
			return "Prompt: " + truncatePromptLine(prompt)
		}
	}
	return ""
}

func piToolName(p piPayload) string {
	for _, name := range []string{p.ToolName, p.ToolNameSnake, p.Name, p.Tool.ToolName, p.Tool.ToolNameSnake, p.Tool.Name} {
		if clean := strings.TrimSpace(name); clean != "" {
			return clean
		}
	}
	return ""
}

func piToolActivity(p piPayload) string {
	if summary := strings.TrimSpace(p.Tool.Summary); summary != "" {
		return truncatePromptLine(summary)
	}
	name := piToolName(p)
	args := piArgsSnippet(piToolArgs(p))
	if name == "" {
		return args
	}
	if args == "" {
		return truncatePromptLine(name)
	}
	return truncatePromptLine(name + ": " + args)
}

func piToolArgs(p piPayload) interface{} {
	for _, value := range []interface{}{p.Args, p.Arguments, p.Input, p.Tool.Args, p.Tool.Arguments, p.Tool.Input} {
		if value != nil {
			return value
		}
	}
	return nil
}

func piArgsSnippet(value interface{}) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return truncatePromptLine(v)
	case map[string]interface{}:
		for _, key := range []string{"command", "cmd", "path", "file_path", "pattern", "query", "description", "prompt", "text"} {
			if s, ok := v[key].(string); ok && strings.TrimSpace(s) != "" {
				return truncatePromptLine(s)
			}
		}
		data, err := json.Marshal(v)
		if err != nil {
			return ""
		}
		return truncatePromptLine(string(data))
	default:
		data, err := json.Marshal(v)
		if err != nil {
			return fmt.Sprint(v)
		}
		return truncatePromptLine(string(data))
	}
}

func piLastMessageText(p piPayload) string {
	for i := len(p.Messages) - 1; i >= 0; i-- {
		if text := piTextFromMessage(p.Messages[i]); text != "" {
			return text
		}
	}
	if text := piTextFromMessage(p.Message); text != "" {
		return text
	}
	if text := piTextFromContent(p.AssistantMessageEvent.Content); text != "" {
		return text
	}
	if text, ok := p.AssistantMessageEvent.Delta.(string); ok && strings.TrimSpace(text) != "" {
		return text
	}
	if strings.TrimSpace(p.Snippet) != "" {
		return p.Snippet
	}
	if p.Recent != nil {
		clean := cleanPiRecent(p.Recent)
		if len(clean) > 0 {
			return clean[len(clean)-1]
		}
	}
	if strings.TrimSpace(p.Text) != "" {
		return p.Text
	}
	if strings.TrimSpace(p.Prompt) != "" {
		return p.Prompt
	}
	return ""
}

func piTextFromMessage(value interface{}) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case map[string]interface{}:
		if role, _ := v["role"].(string); role != "" && role != "assistant" {
			return ""
		}
		if text := piTextFromContent(v["content"]); text != "" {
			return text
		}
		if text, _ := v["text"].(string); strings.TrimSpace(text) != "" {
			return text
		}
	}
	return ""
}

func piTextFromContent(value interface{}) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case []interface{}:
		parts := make([]string, 0, len(v))
		for _, item := range v {
			obj, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			kind, _ := obj["type"].(string)
			if kind != "" && kind != "text" {
				continue
			}
			text, _ := obj["text"].(string)
			if strings.TrimSpace(text) != "" {
				parts = append(parts, text)
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func cleanPiRecent(lines []string) []string {
	const limit = 40
	clean := make([]string, 0, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		clean = append(clean, line)
	}
	if len(clean) > limit {
		clean = clean[len(clean)-limit:]
	}
	return clean
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ErrHookSubagentSuppressed is exported for tests that want to assert
// the subagent suppression behaviour from outside the package.
var ErrHookSubagentSuppressed = errors.New("hook event suppressed by subagent rule")
