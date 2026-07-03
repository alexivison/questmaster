package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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

	// Store reads and updates session manifests. Hook handlers use it to
	// capture agent-native resume IDs as they appear.
	Store hookManifestStore

	// TmuxClient writes captured IDs into the tmux session environment.
	TmuxClient hookTmuxEnvironmentSetter

	// LoadTranscriptTail returns up to ~64 KiB from the end of a Claude
	// transcript_path file. Returns (nil, nil) if the file is missing or
	// unreadable; Stop hooks must remain best-effort when transcripts lag.
	LoadTranscriptTail func(path string) ([]byte, error)

	// Update applies a tracker-style locked read-modify-write to the
	// session's state.json. Returning false from mutate skips the disk
	// write (used for the hot-path conditional flush).
	Update func(sessionID string, mutate func(*state.SessionState) bool) error

	// AppendEvent appends one line to state.jsonl. Best-effort: a write
	// failure here is logged but does not fail the hook.
	AppendEvent func(sessionID string, ev state.StateEvent) error

	// UpdateAndLog folds the event append and the state.json
	// read-modify-write into a single flock-guarded critical section: it
	// always appends ev, then conditionally writes state.json when mutate
	// returns true. Hot-path handlers use this instead of an AppendEvent +
	// Update pair to take one lock per event instead of two.
	UpdateAndLog func(sessionID string, ev state.StateEvent, mutate func(*state.SessionState) bool) error
}

type hookManifestStore interface {
	Read(sessionID string) (state.Manifest, error)
	Update(sessionID string, fn func(*state.Manifest)) error
}

type hookTmuxEnvironmentSetter interface {
	SetEnvironment(ctx context.Context, session, key, value string) error
	SetPaneOption(ctx context.Context, target, key, value string) error
	RenameWindow(ctx context.Context, target, name string) error
}

// defaultHookRunner wires HookRunner to the real internal/state package.
func defaultHookRunner() *HookRunner {
	return newHookRunner(state.OpenStore(state.StateRoot()), tmux.NewExecClient())
}

func newHookRunner(store hookManifestStore, client hookTmuxEnvironmentSetter) *HookRunner {
	return &HookRunner{
		Now:                time.Now,
		Store:              store,
		TmuxClient:         client,
		LoadTranscriptTail: loadTranscriptTail,
		Update:             state.UpdateSessionState,
		AppendEvent:        state.AppendStateEvent,
		UpdateAndLog:       state.UpdateAndLog,
	}
}

// updateAndLog folds the per-event JSONL append and the state.json
// read-modify-write into a single flock-guarded critical section when the
// runner exposes UpdateAndLog (the production wiring), taking one lock per
// event instead of two. It falls back to the separate AppendEvent + Update
// pair when UpdateAndLog is unset (e.g. test runners that stub the two
// halves independently), preserving identical observable behavior: the
// event is always appended and Update's mutate decides the state write.
//
// It returns the append and update errors separately so callers can keep
// their agent-specific stderr messages.
func (r *HookRunner) updateAndLog(sessionID string, ev state.StateEvent, mutate func(*state.SessionState) bool) (appendErr, updateErr error) {
	if r.UpdateAndLog != nil {
		// The combined path logs the event and writes state under one lock;
		// surface its single error as the update error so the (rare) failure
		// is still reported.
		return nil, r.UpdateAndLog(sessionID, ev, mutate)
	}
	if r.AppendEvent != nil {
		appendErr = r.AppendEvent(sessionID, ev)
	}
	if r.Update != nil {
		updateErr = r.Update(sessionID, mutate)
	}
	return appendErr, updateErr
}

// hookOptions holds parsed CLI inputs.
type hookOptions struct {
	ctx     context.Context
	agent   string
	action  string
	session string
	stdin   []byte
}

// newHookCmd builds `questmaster hook <agent> <action>`. The tmux/state
// args mirror other subcommand factories for consistency; this hot path
// must never call methods that scan the state root (e.g. DiscoverSessions).
func newHookCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{
		Use:   "hook <agent> <action>",
		Short: "Internal: process an agent hook event (called by installed shell scripts)",
		Long: "questmaster hook is the entry point for agent-native hooks. It is\n" +
			"invoked by the small shell scripts written by `questmaster hooks install`\n" +
			"and writes the per-session state.json / state.jsonl.\n\n" +
			"Hook failures must never propagate to the agent: this command always\n" +
			"exits 0 (any internal error is logged to stderr).",
		Args:          cobra.ExactArgs(2),
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts := hookOptions{ctx: cmd.Context(), agent: args[0], action: args[1], session: sessionFlag}
			if data, err := readStdinNonBlocking(cmd.InOrStdin()); err == nil {
				opts.stdin = data
			}
			runHook(newHookRunner(store, client), opts, cmd.ErrOrStderr())
			return nil
		},
	}
	cmd.Flags().StringVar(&sessionFlag, "session", "", "session ID (defaults to $QUESTMASTER_SESSION)")
	return cmd
}

// runHook is the testable core. It never returns an error; all failures
// are logged to stderr and otherwise swallowed so installed shell scripts
// can `exec` this binary with no agent-visible side effect.
func runHook(r *HookRunner, opts hookOptions, stderr io.Writer) {
	if opts.ctx == nil {
		opts.ctx = context.Background()
	}
	id := opts.session
	if id == "" {
		id = state.SessionIDFromEnv()
	}
	if id == "" {
		return
	}
	if !state.IsValidSessionID(id) {
		fmt.Fprintf(stderr, "questmaster hook: invalid QUESTMASTER_SESSION %q\n", id)
		return
	}

	switch opts.agent {
	case "claude":
		handleClaude(r, id, opts, stderr)
	case "codex":
		handleCodex(r, id, opts, stderr)
	case "pi":
		handlePi(r, id, opts, stderr)
	case "omp":
		handleOmp(r, id, opts, stderr)
	case "opencode":
		handleOpenCode(r, id, opts, stderr)
	default:
		fmt.Fprintf(stderr, "questmaster hook: unknown agent %q\n", opts.agent)
	}
}

var stdinLooksInteractive = func(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice != 0
}

// readStdinNonBlocking reads up to 64 KiB from stdin when stdin is piped or
// otherwise non-interactive. A real TTY must not be read: ReadAll would wait
// for a line/EOF and hook invocations from an interactive shell would hang.
func readStdinNonBlocking(r io.Reader) ([]byte, error) {
	if r == nil {
		return nil, nil
	}
	if stdinLooksInteractive(r) {
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
// in upstream Claude should degrade snippets rather than break state updates.
type claudePayload struct {
	AgentID              string                 `json:"agent_id"`
	SessionID            string                 `json:"session_id"`
	ToolName             string                 `json:"tool_name"`
	ToolInput            map[string]interface{} `json:"tool_input"`
	Prompt               string                 `json:"prompt"`
	Message              string                 `json:"message"`
	Text                 string                 `json:"text"`
	TranscriptPath       string                 `json:"transcript_path"`
	Result               string                 `json:"result"`
	LastAssistantMessage string                 `json:"last_assistant_message"`
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

	// Compute the desired pane mutation. Subagent suppression is
	// Claude-specific because only Claude carries an agent_id discriminator.
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
		// clearStaleNotificationActivity flips on for PostToolUse so
		// the mutation closure can drop a stale "Notification: …"
		// snippet left over from a permission/approval prompt that
		// has now been resolved.
		clearStaleNotificationActivity bool
	)

	switch opts.action {
	case "starting":
		setState = "starting"
		setActivity = "started"
		lastKind = "SessionStart"
	case "working":
		// UserPromptSubmit marks the primary pane as working at turn start.
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
		// AskUserQuestion is Claude's permission-gated prompt-the-user
		// tool. Mirror Pi's waiting_for_user rendering: flip to blocked
		// and surface the actual question text instead of the generic
		// "Agent: …" snippet. Falls back to setActivity from
		// activityForTool (i.e. "AskUserQuestion") if the payload shape
		// doesn't expose a question string.
		if payload.ToolName == "AskUserQuestion" {
			setState = "blocked"
			if q := askUserQuestionText(payload.ToolInput); q != "" {
				setActivity = "Question: " + truncatePromptLine(q)
			}
		}
	case "tool_end":
		setState = "working"
		clearTool = true
		lastKind = "PostToolUse"
		suppressStateForSubagent = true
		// Activity stays as the most recent PreToolUse snippet, except
		// when a Notification overwrote it with "Notification: …".
		// Once the user resolves the permission prompt PostToolUse
		// fires; flag the closure to drop the stale notification line
		// so the pane doesn't keep advertising a prompt that is no
		// longer active.
		clearStaleNotificationActivity = true
	case "done":
		if !isSubagent {
			setState = "done"
		}
		// Prefer the payload-provided last assistant message — Claude's
		// Stop fires before the transcript file is fully flushed, so
		// reading the file races and frequently returns no assistant
		// record. Fall back to the transcript tail when the payload
		// field is absent.
		if payload.LastAssistantMessage != "" {
			setActivity = truncatePromptLine(payload.LastAssistantMessage)
		} else if tail, err := r.LoadTranscriptTail(payload.TranscriptPath); err == nil && len(tail) > 0 {
			if snippet := saidSnippet(tail); snippet != "" {
				setActivity = snippet
			}
		}
		lastKind = "Stop"
	case "subagent_stop":
		// SubagentStop updates Activity only; the parent State belongs to
		// the primary agent's own lifecycle hooks.
		result := strings.TrimSpace(payload.Result)
		if result == "" {
			result = strings.TrimSpace(payload.Text)
		}
		if result != "" {
			setActivity = "Subagent: " + truncatePromptLine(result)
		}
		lastKind = "SubagentStop"
	case "blocked":
		msg := payload.Message
		if msg == "" {
			msg = payload.Text
		}
		lastKind = "Notification"
		// Claude fires Notification for both genuine permission/approval
		// prompts AND for plain idle-waiting ("Claude is waiting for your
		// input"). The idle-waiting variant arrives after Stop and would
		// otherwise clobber state=done with state=blocked, painting the
		// pane red while the agent is just idle. Treat any message
		// starting with "Claude is waiting" as informational: only update
		// LastKind, leave State and Activity alone.
		if !isIdleWaitingNotification(msg) {
			setState = "blocked"
			setActivity = "Notification: " + truncatePromptLine(msg)
		}
	case "stopped":
		setState = "stopped"
		lastKind = "SessionEnd"
	default:
		fmt.Fprintf(stderr, "questmaster hook claude: unknown action %q\n", opts.action)
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
		// parent pane shouldn't show the subagent message as if the
		// parent just spoke. The SubagentStop event carries the actual
		// subagent snippet.
		setState = ""
		setActivity = ""
	}

	ev.State = setState
	ev.Activity = setActivity
	ev.Tool = setTool
	ev.Kind = lastKind

	firstPrompt := false
	appendErr, mutateErr := r.updateAndLog(sessionID, ev, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "claude"}
		}
		// Snapshot the renderer-visible fields before mutation so we can
		// skip writes when the dot/snippet output would be identical.
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent, WorkingSince         time.Time
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.WorkingSince}

		// The first UserPromptSubmit arrives while the pane is still in its
		// post-SessionStart "starting" state. That is the only turn worth a
		// manifest title check, so steady-state prompts never touch it.
		firstPrompt = opts.action == "working" && prev.State == "starting"

		// Notification fires after the AskUserQuestion PreToolUse with a
		// generic "Claude needs your permission to use AskUserQuestion"
		// message. The PreToolUse already painted "Question: …" — keep
		// it instead of clobbering with the less useful notification
		// snippet. State is already blocked, so suppressing the State
		// write is a no-op but kept for symmetry with the Activity
		// preservation.
		preserveAskUserQuestion := opts.action == "blocked" &&
			pane.Tool == "AskUserQuestion" &&
			strings.HasPrefix(pane.Activity, "Question: ")
		if preserveAskUserQuestion {
			setState = ""
			setActivity = ""
		}

		if setState != "" {
			pane.State = setState
		}
		normalizeHookWorkingSince(&pane, prev.State, prev.LastEvent, now)
		if setActivity != "" {
			pane.Activity = setActivity
		}
		if setTool != "" {
			pane.Tool = setTool
		} else if clearTool {
			pane.Tool = ""
		}
		if clearStaleNotificationActivity && strings.HasPrefix(pane.Activity, "Notification: ") {
			pane.Activity = ""
		}
		if lastKind != "" {
			pane.LastKind = lastKind
		}
		pane.LastEvent = now
		pane.Seq = now.UnixNano()
		pane.Agent = "claude"
		pane.Role = role
		ss.Panes[role] = pane

		// Conditional flush: rewrite state.json only when renderer-visible
		// fields changed. The JSONL event stream still records timestamp-only
		// repeats.
		if pane.State == prev.State &&
			pane.Activity == prev.Activity &&
			pane.Tool == prev.Tool &&
			pane.LastKind == prev.LastKind &&
			pane.WorkingSince.Equal(prev.WorkingSince) {
			return false
		}
		return true
	})
	if appendErr != nil {
		fmt.Fprintf(stderr, "questmaster hook claude: append event: %v\n", appendErr)
	}
	if mutateErr != nil {
		fmt.Fprintf(stderr, "questmaster hook claude: update state: %v\n", mutateErr)
	}

	if firstPrompt {
		maybeDeriveTitle(opts.ctx, r, sessionID, payload.Prompt, stderr)
	}
	if opts.action == "stopped" {
		clearAdoptedAgentOnExit(opts.ctx, r, stderr, sessionID, "claude")
	} else if payload.SessionID != "" {
		captureResumeID(opts.ctx, r, stderr, sessionID, "claude_session_id", "CLAUDE_SESSION_ID", payload.SessionID, "claude")
	}
}

// normalizeHookWorkingSince keeps renderer-visible working duration stable
// across legacy state files that predate working_since.
func normalizeHookWorkingSince(pane *state.PaneState, prevState string, prevLastEvent, now time.Time) {
	if pane.State != "working" {
		pane.WorkingSince = time.Time{}
		return
	}
	if prevState != "working" {
		pane.WorkingSince = now
		return
	}
	if !pane.WorkingSince.IsZero() {
		return
	}
	if !prevLastEvent.IsZero() {
		pane.WorkingSince = prevLastEvent
		return
	}
	pane.WorkingSince = now
}

// activityForTool formats the Activity field for a PreToolUse event.
// Falls back to "Tool: <name>" when the tool isn't one of the rich-format
// cases handled below.
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
		return "Edit: " + truncatePath(get("file_path"))
	case "Read":
		return "Read: " + truncatePath(get("file_path"))
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

// askUserQuestionText extracts the first question's text from an
// AskUserQuestion tool_input payload, whose shape is
// `{ "questions": [{ "question": "...", "options": [...], ... }, ...] }`.
// Returns "" when the shape doesn't match so callers can fall back to
// a generic activity snippet.
func askUserQuestionText(in map[string]interface{}) string {
	qs, ok := in["questions"].([]interface{})
	if !ok || len(qs) == 0 {
		return ""
	}
	first, ok := qs[0].(map[string]interface{})
	if !ok {
		return ""
	}
	q, _ := first["question"].(string)
	return q
}

// truncatePromptLine keeps activity snippets single-line, strips leading
// env-var assignments, and caps display length.
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

// isIdleWaitingNotification reports whether a Notification message is
// the idle-waiting variant ("Claude is waiting for your input") rather
// than a genuine permission/approval prompt. Claude fires both through
// the same hook, but only the latter should flip the pane to blocked.
// The idle-waiting variant typically arrives after Stop and means the
// agent finished its turn — keeping state=done is the correct
// rendering.
func isIdleWaitingNotification(msg string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(msg)), "claude is waiting")
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

// loadTranscriptTail reads up to ~64 KiB from the end of the transcript
// file. Missing or unreadable transcripts must not fail the hook, so any
// error returns (nil, nil).
//
// 64 KiB (16× the original 4 KiB) is chosen empirically: Claude appends
// many post-message metadata records (attachment, queue-operation,
// system, last-prompt, custom-title, agent-name, permission-mode,
// pr-link, bridge-session, agent-color) AFTER the last assistant
// message. In observed transcripts up to ~1 MB, the trailing assistant
// message landed within ~32 KiB of EOF. 4 KiB undersized; 64 KiB covers
// the empirical worst case while staying small enough that the hot path
// remains well under the <20 ms latency budget.
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
	const tailSize = 64 * 1024
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
	// Walk the tail line-by-line from EOF without allocating a []string of
	// every line: most transcripts surface the assistant message within the
	// last few lines, so the reverse LastIndexByte scan returns early.
	s := string(tail)
	for end := len(s); end > 0; {
		start := strings.LastIndexByte(s[:end], '\n') + 1
		raw := strings.TrimSpace(s[start:end])
		end = start - 1
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
	Message              string                 `json:"message"`
	Permission           string                 `json:"permission"`
	Command              string                 `json:"command"`
	SessionID            string                 `json:"session_id"`
	ThreadID             string                 `json:"thread_id"`
	ConversationID       string                 `json:"conversation_id"`
	TranscriptPath       string                 `json:"transcript_path"`
	AgentTranscriptPath  string                 `json:"agent_transcript_path"`
	LastAssistantMessage string                 `json:"last_assistant_message"`
}

var codexUUIDish = regexp.MustCompile(`[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}`)

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
	threadID := codexResumeID(payload)
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
		setActivity = "started"
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
		if isCodexRequestUserInputTool(payload.ToolName) {
			setState = "blocked"
			setActivity = codexRequestUserInputActivity(payload)
		}
	case "tool_end":
		setState = "working"
		clearTool = true
		lastKind = "PostToolUse"
	case "permission":
		setState = "blocked"
		setActivity = codexPermissionActivity(payload)
		lastKind = "PermissionRequest"
	case "done":
		setState = "done"
		if payload.LastAssistantMessage != "" {
			setActivity = truncatePromptLine(payload.LastAssistantMessage)
		} else if tail, err := r.LoadTranscriptTail(payload.TranscriptPath); err == nil && len(tail) > 0 {
			if snippet := saidSnippet(tail); snippet != "" {
				setActivity = snippet
			}
		}
		lastKind = "Stop"
	default:
		fmt.Fprintf(stderr, "questmaster hook codex: unknown action %q\n", opts.action)
		return
	}

	ev.State = setState
	ev.Activity = setActivity
	ev.Tool = setTool
	ev.Kind = lastKind

	firstPrompt := false
	appendErr, mutateErr := r.updateAndLog(sessionID, ev, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: "codex"}
		}
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent, WorkingSince         time.Time
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.WorkingSince}

		// Only the first prompt (pane still "starting") is worth a manifest
		// title check; steady-state prompts never touch it.
		firstPrompt = opts.action == "working" && prev.State == "starting"
		clearStaleQuestionActivity := opts.action == "tool_end" &&
			isCodexRequestUserInputTool(pane.Tool) &&
			strings.HasPrefix(pane.Activity, "Question: ")

		if setState != "" {
			pane.State = setState
		}
		normalizeHookWorkingSince(&pane, prev.State, prev.LastEvent, now)
		if setActivity != "" {
			pane.Activity = setActivity
		} else if clearStaleQuestionActivity {
			pane.Activity = ""
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
			pane.WorkingSince.Equal(prev.WorkingSince) {
			return false
		}
		return true
	})
	if appendErr != nil {
		fmt.Fprintf(stderr, "questmaster hook codex: append event: %v\n", appendErr)
	}
	if mutateErr != nil {
		fmt.Fprintf(stderr, "questmaster hook codex: update state: %v\n", mutateErr)
	}
	if firstPrompt {
		maybeDeriveTitle(opts.ctx, r, sessionID, payload.Prompt, stderr)
	}
	if threadID != "" {
		captureResumeID(opts.ctx, r, stderr, sessionID, "codex_thread_id", "CODEX_THREAD_ID", threadID, "codex")
	}
}

func codexResumeID(p codexPayload) string {
	for _, candidate := range []string{
		os.Getenv("CODEX_THREAD_ID"),
		p.ThreadID,
		p.SessionID,
		p.ConversationID,
		codexResumeIDFromTranscriptPath(p.TranscriptPath),
		codexResumeIDFromTranscriptPath(p.AgentTranscriptPath),
	} {
		if id := cleanCodexResumeID(candidate); id != "" {
			return id
		}
	}
	return ""
}

func codexResumeIDFromTranscriptPath(transcriptPath string) string {
	transcriptPath = strings.TrimSpace(transcriptPath)
	if transcriptPath == "" {
		return ""
	}
	return codexUUIDish.FindString(filepath.Base(transcriptPath))
}

func cleanCodexResumeID(id string) string {
	return state.SanitizeResumeID(strings.TrimSpace(id))
}

const (
	adoptedPaneManifestKey   = "adopted_pane"
	titleProvisionalExtraKey = "title_provisional"
)

func captureResumeID(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID, manifestKey, envKey, value, agent string) {
	// Codex exposes the new thread ID through CODEX_THREAD_ID, so that
	// env var cannot prove the tmux session env is already current.
	skipTmuxEnv := envKey != "CODEX_THREAD_ID" && os.Getenv(envKey) == value
	tmuxPane := os.Getenv("TMUX_PANE")
	if r.Store != nil {
		manifest, err := r.Store.Read(sessionID)
		if err != nil {
			fmt.Fprintf(stderr, "questmaster hook %s: read manifest: %v\n", agent, err)
		} else {
			adopt := len(manifest.Agents) == 0
			tracksAgent := manifestTracksAgent(manifest, agent)
			adoptedPane, adoptionManaged := manifestAdoptedPane(manifest)
			succession := !adopt && !tracksAgent && adoptionManaged && tmuxPane != "" && adoptedPane == tmuxPane
			if !adopt && !tracksAgent && !succession {
				return
			}
			persisted := !succession && resumeIDPersisted(manifest, manifestKey, agent, value)
			if persisted {
				// The hook that persisted this value also set the tmux env; the
				// manifest and the tmux session share a lifetime, so skip the
				// per-event tmux fork+exec on every later event.
				skipTmuxEnv = true
			}
			if adopt || succession || !persisted {
				tagPrimary := false
				nextCwd := ""
				if adopt || succession {
					nextCwd, _ = os.Getwd()
				}
				if err := r.Store.Update(sessionID, func(m *state.Manifest) {
					if len(m.Agents) == 0 {
						m.Agents = []state.AgentManifest{{
							Name: agent, Role: "primary", CLI: agent,
							ResumeID: value, Window: tmux.WindowWorkspace,
						}}
						if nextCwd != "" {
							m.Cwd = nextCwd
						}
						m.SetExtra(adoptedPaneManifestKey, tmuxPane)
						tagPrimary = tmuxPane != ""
					} else if succession && !manifestTracksAgent(*m, agent) {
						lockedPane, ok := manifestAdoptedPane(*m)
						if !ok || tmuxPane == "" || lockedPane != tmuxPane {
							return
						}
						m.Agents = []state.AgentManifest{{
							Name: agent, Role: "primary", CLI: agent,
							ResumeID: value, Window: tmux.WindowWorkspace,
						}}
						if nextCwd != "" {
							m.Cwd = nextCwd
						}
						m.SetExtra(adoptedPaneManifestKey, tmuxPane)
						m.SetExtra(titleProvisionalExtraKey, "1")
						tagPrimary = true
					}
					if !manifestTracksAgent(*m, agent) {
						return
					}
					for i := range m.Agents {
						if m.Agents[i].Name == agent {
							m.Agents[i].ResumeID = value
						}
					}
					m.SetExtra(manifestKey, value)
				}); err != nil {
					fmt.Fprintf(stderr, "questmaster hook %s: update manifest: %v\n", agent, err)
				}
				if tagPrimary && r.TmuxClient != nil {
					if err := r.TmuxClient.SetPaneOption(ctx, tmuxPane, tmux.PaneRoleOption, tmux.RolePrimary); err != nil {
						fmt.Fprintf(stderr, "questmaster hook %s: tag adopted pane: %v\n", agent, err)
					}
				}
			}
		}
	}
	if r.TmuxClient != nil && !skipTmuxEnv {
		if err := r.TmuxClient.SetEnvironment(ctx, sessionID, envKey, value); err != nil {
			fmt.Fprintf(stderr, "questmaster hook %s: set tmux env: %v\n", agent, err)
		}
	}
}

func manifestTracksAgent(m state.Manifest, agent string) bool {
	for _, spec := range m.Agents {
		if spec.Name == agent {
			return true
		}
	}
	return false
}

func manifestAdoptedPane(m state.Manifest) (string, bool) {
	if m.Extra == nil {
		return "", false
	}
	_, ok := m.Extra[adoptedPaneManifestKey]
	return m.ExtraString(adoptedPaneManifestKey), ok
}

func clearAdoptedAgentOnExit(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID, agent string) {
	if r.Store == nil {
		return
	}
	manifest, err := r.Store.Read(sessionID)
	if err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: read manifest: %v\n", agent, err)
		return
	}
	if !manifestAdoptedAgent(manifest, agent) {
		return
	}
	tmuxPane := os.Getenv("TMUX_PANE")
	retagShell := false
	if err := r.Store.Update(sessionID, func(m *state.Manifest) {
		if !manifestAdoptedAgent(*m, agent) {
			return
		}
		m.Agents = nil
		delete(m.Extra, adoptedPaneManifestKey)
		delete(m.Extra, "title_locked")
		m.Title = "Shell"
		m.SetExtra(titleProvisionalExtraKey, "1")
		m.WindowName = ""
		retagShell = tmuxPane != ""
	}); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: clear adopted agent: %v\n", agent, err)
		return
	}
	if r.TmuxClient == nil {
		return
	}
	if retagShell {
		if err := r.TmuxClient.SetPaneOption(ctx, tmuxPane, tmux.PaneRoleOption, tmux.RoleShell); err != nil {
			fmt.Fprintf(stderr, "questmaster hook %s: retag adopted pane: %v\n", agent, err)
		}
	}
}

func manifestAdoptedAgent(m state.Manifest, agent string) bool {
	if _, ok := manifestAdoptedPane(m); !ok {
		return false
	}
	return len(m.Agents) == 1 && m.Agents[0].Name == agent
}

// maybeDeriveTitle fills a blank or provisional session title from the user's
// first message, mirroring the way Claude's app names a conversation. It is a
// no-op once the user locked an explicit title, so only the first turn writes.
// Best-effort: failures are logged but never block the hook.
func maybeDeriveTitle(ctx context.Context, r *HookRunner, sessionID, prompt string, stderr io.Writer) {
	if r.Store == nil {
		return
	}
	title := session.TitleFromPrompt(prompt)
	if title == "" {
		return
	}
	manifest, err := r.Store.Read(sessionID)
	if err != nil {
		// Best-effort: a missing or unreadable manifest just means there is
		// no title to fill in. Stay silent so the hook never adds noise.
		return
	}
	if manifest.ExtraString("title_locked") != "" ||
		(strings.TrimSpace(manifest.Title) != "" && manifest.ExtraString(titleProvisionalExtraKey) == "") {
		return
	}
	if err := r.Store.Update(sessionID, func(m *state.Manifest) {
		// Re-check under the lock: a concurrent turn may have set it.
		if m.ExtraString("title_locked") != "" ||
			(strings.TrimSpace(m.Title) != "" && m.ExtraString(titleProvisionalExtraKey) == "") {
			return
		}
		m.Title = title
		m.WindowName = ""
		delete(m.Extra, titleProvisionalExtraKey)
	}); err != nil {
		fmt.Fprintf(stderr, "questmaster hook: update title: %v\n", err)
		return
	}
}

func resumeIDPersisted(m state.Manifest, manifestKey, agentName, value string) bool {
	if m.ExtraString(manifestKey) != value {
		return false
	}
	for _, spec := range m.Agents {
		if spec.Name == agentName && spec.ResumeID != value {
			return false
		}
	}
	return true
}

func codexPermissionActivity(p codexPayload) string {
	text := strings.TrimSpace(p.Message)
	if text == "" {
		text = codexToolInputString(p.ToolInput, "command", "cmd")
	}
	if text == "" {
		text = strings.TrimSpace(p.Command)
	}
	if text == "" {
		text = strings.TrimSpace(p.Permission)
	}
	if text == "" {
		text = "Permission required"
	}
	return "Permission: " + truncatePromptLine(text)
}

func codexRequestUserInputActivity(p codexPayload) string {
	text := askUserQuestionText(p.ToolInput)
	if text == "" {
		text = strings.TrimSpace(p.Message)
	}
	if text == "" {
		text = strings.TrimSpace(p.Prompt)
	}
	if text == "" {
		text = "User input requested"
	}
	return "Question: " + truncatePromptLine(text)
}

func isCodexRequestUserInputTool(name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	return name == "request_user_input" || strings.HasSuffix(name, ".request_user_input")
}

func activityForCodexTool(p codexPayload) string {
	name := p.ToolName
	in := p.ToolInput
	switch name {
	case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
		return "Edit: " + truncatePath(codexToolInputString(in, "file_path", "path"))
	case "Read":
		return "Read: " + truncatePath(codexToolInputString(in, "file_path", "path"))
	case "Bash", "Shell", "shell":
		return "Bash: " + truncatePromptLine(codexToolInputString(in, "command", "cmd"))
	case "Task":
		return "Agent: " + truncatePromptLine(codexToolInputString(in, "description", "prompt"))
	case "Grep", "Glob", "Search", "rg":
		return "Search: " + truncatePromptLine(codexToolInputString(in, "pattern", "query"))
	case "":
		return ""
	default:
		return name
	}
}

func codexToolInputString(in map[string]interface{}, keys ...string) string {
	for _, k := range keys {
		if v, ok := in[k].(string); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
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
	handlePiLike(r, sessionID, opts, stderr, "pi")
}

// handleOmp processes oh-my-pi activity-sidecar events. omp is a Pi fork that
// emits the same event vocabulary through its extension API, so it reuses the
// Pi event handler with a distinct agent identity.
func handleOmp(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer) {
	handlePiLike(r, sessionID, opts, stderr, "omp")
}

// handlePiLike processes a Pi-style activity event for the named agent
// ("pi" or "omp"). Both agents share the sidecar event contract and the
// tolerant payload parser; only the recorded agent identity differs.
func handlePiLike(r *HookRunner, sessionID string, opts hookOptions, stderr io.Writer, agentName string) {
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
			setActivity = "started"
		}
		piPrompt := payload.Prompt
		if strings.TrimSpace(piPrompt) == "" {
			piPrompt = payload.Text
		}
		maybeDeriveTitle(opts.ctx, r, sessionID, piPrompt, stderr)
	case "message_update", "message_end":
		setState = "working"
		if text := piLastMessageText(payload); text != "" {
			setActivity = truncatePromptLine(text)
		} else {
			setActivity = "Replying…"
		}
	case "tool_execution_start":
		setState = "working"
		setTool = piToolName(payload)
		setActivity = piToolActivity(payload)
	case "tool_execution_end":
		setState = "working"
		clearTool = true
	case "waiting_for_user":
		setState = "blocked"
		setTool = piToolName(payload)
		setActivity = "Question: " + truncatePromptLine(piQuestionText(payload))
		lastKind = "waiting_for_user"
	case "agent_end":
		setState = "done"
		clearTool = true
		if text := piLastMessageText(payload); text != "" {
			setActivity = truncatePromptLine(text)
		}
	case "session_shutdown":
		setState = "stopped"
		clearTool = true
	default:
		fmt.Fprintf(stderr, "questmaster hook %s: unknown action %q\n", agentName, opts.action)
		return
	}

	recent, hasRecent := piRecentForAction(opts.action, payload)
	sessionFile := strings.TrimSpace(payload.SessionFile)
	piSessionID := strings.TrimSpace(payload.PiSessionID)

	ev := state.StateEvent{
		Ts:       now,
		Agent:    agentName,
		Role:     "primary",
		Action:   opts.action,
		State:    setState,
		Activity: setActivity,
		Tool:     setTool,
		Kind:     lastKind,
	}
	if sessionFile != "" || piSessionID != "" || hasRecent {
		fields := make(map[string]interface{}, 3)
		if sessionFile != "" {
			fields["session_file"] = sessionFile
		}
		if piSessionID != "" {
			fields["pi_session_id"] = piSessionID
		}
		if hasRecent {
			fields["recent_count"] = len(recent)
		}
		ev.Fields = fields
	}

	appendErr, mutateErr := r.updateAndLog(sessionID, ev, func(ss *state.SessionState) bool {
		role := "primary"
		ss.SeenAt = now
		pane, exists := ss.Panes[role]
		if !exists {
			pane = state.PaneState{Role: role, Agent: agentName}
		}
		prev := struct {
			State, Activity, Tool, LastKind string
			LastEvent, WorkingSince         time.Time
			Recent                          []string
			SessionFile, PiSessionID        string
		}{pane.State, pane.Activity, pane.Tool, pane.LastKind, pane.LastEvent, pane.WorkingSince, pane.Recent, pane.SessionFile, pane.PiSessionID}

		preserveBlockedQuestion := opts.action == "tool_execution_start" && pane.State == "blocked" && pane.LastKind == "waiting_for_user"
		clearStaleQuestionActivity := opts.action == "tool_execution_end" && pane.LastKind == "waiting_for_user" && strings.HasPrefix(pane.Activity, "Question: ")
		if preserveBlockedQuestion {
			setState = ""
			setActivity = ""
			setTool = ""
			clearTool = false
			lastKind = pane.LastKind
		}

		if setState != "" {
			pane.State = setState
		}
		normalizeHookWorkingSince(&pane, prev.State, prev.LastEvent, now)
		if setActivity != "" {
			pane.Activity = setActivity
		} else if clearStaleQuestionActivity {
			pane.Activity = ""
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
		pane.Agent = agentName
		pane.Role = role
		ss.Panes[role] = pane

		if pane.State == prev.State &&
			pane.Activity == prev.Activity &&
			pane.Tool == prev.Tool &&
			pane.LastKind == prev.LastKind &&
			pane.WorkingSince.Equal(prev.WorkingSince) &&
			slices.Equal(pane.Recent, prev.Recent) &&
			pane.SessionFile == prev.SessionFile &&
			pane.PiSessionID == prev.PiSessionID {
			return false
		}
		return true
	})
	if appendErr != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: append event: %v\n", agentName, appendErr)
	}
	if mutateErr != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: update state: %v\n", agentName, mutateErr)
	}
	if opts.action == "session_shutdown" {
		clearAdoptedAgentOnExit(opts.ctx, r, stderr, sessionID, agentName)
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
			return "You: " + truncatePromptLine(prompt)
		}
	}
	return ""
}

func piQuestionText(p piPayload) string {
	for _, text := range []string{p.Prompt, p.Tool.Summary, p.Text, p.Snippet} {
		if strings.TrimSpace(text) != "" {
			return text
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
	name := piToolName(p)
	args := piToolArgs(p)
	summary := strings.TrimSpace(p.Tool.Summary)
	fallbackSummary := func() string {
		if summary == "" {
			return ""
		}
		return truncatePromptLine(summary)
	}
	fallbackArg := func(keys ...string) string {
		if value := piToolArgString(args, keys...); value != "" {
			return value
		}
		return piSummaryDetail(summary)
	}

	if name == "" {
		if snippet := piArgsSnippet(args); snippet != "" {
			return snippet
		}
		return fallbackSummary()
	}

	switch piToolKind(name) {
	case "edit":
		path := fallbackArg("file_path", "path", "filePath")
		if path == "" {
			if summary := fallbackSummary(); summary != "" {
				return summary
			}
		}
		return "Edit: " + truncatePath(path)
	case "read":
		path := fallbackArg("file_path", "path", "filePath")
		if path == "" {
			if summary := fallbackSummary(); summary != "" {
				return summary
			}
		}
		return "Read: " + truncatePath(path)
	case "bash":
		command := fallbackArg("command", "cmd")
		if command == "" {
			if summary := fallbackSummary(); summary != "" {
				return summary
			}
		}
		return "Bash: " + truncatePromptLine(command)
	case "agent":
		description := fallbackArg("description", "prompt")
		if description == "" {
			if summary := fallbackSummary(); summary != "" {
				return summary
			}
		}
		return "Agent: " + truncatePromptLine(description)
	case "search":
		pattern := fallbackArg("pattern", "query", "path")
		if pattern == "" {
			if summary := fallbackSummary(); summary != "" {
				return summary
			}
		}
		return "Search: " + truncatePromptLine(pattern)
	}
	return name
}

func piToolKind(name string) string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "edit", "write", "multiedit", "multi_edit", "notebookedit", "notebook_edit", "apply_patch":
		return "edit"
	case "read", "read_file":
		return "read"
	case "bash", "shell", "sh":
		return "bash"
	case "task", "agent":
		return "agent"
	case "grep", "glob", "search", "rg", "ripgrep", "find":
		return "search"
	default:
		return ""
	}
}

func piToolArgString(value interface{}, keys ...string) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		clean := strings.TrimSpace(v)
		if clean == "" {
			return ""
		}
		var parsed map[string]interface{}
		if err := json.Unmarshal([]byte(clean), &parsed); err == nil {
			return piToolArgString(parsed, keys...)
		}
		return clean
	case map[string]interface{}:
		for _, key := range keys {
			if s, ok := v[key].(string); ok && strings.TrimSpace(s) != "" {
				return strings.TrimSpace(s)
			}
		}
	case map[string]string:
		for _, key := range keys {
			if s := strings.TrimSpace(v[key]); s != "" {
				return s
			}
		}
	}
	return ""
}

func piSummaryDetail(summary string) string {
	summary = strings.TrimSpace(summary)
	if summary == "" {
		return ""
	}
	if i := strings.Index(summary, ":"); i >= 0 {
		return strings.TrimSpace(summary[i+1:])
	}
	return ""
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
