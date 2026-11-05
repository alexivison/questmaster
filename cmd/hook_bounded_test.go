package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type repeatedHookByte struct{ value byte }

func (r repeatedHookByte) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = r.value
	}
	return len(p), nil
}

func codexToolEndWithResponse(size int64) io.Reader {
	return io.MultiReader(
		strings.NewReader(`{"hook_event_name":"PostToolUse","tool_response":"`),
		io.LimitReader(repeatedHookByte{value: 'x'}, size),
		strings.NewReader(`","tool_name":"Edit","tool_use_id":"call-1"}`),
	)
}

func TestHookCodexLargeToolEndClosesToolWithoutRetainingResponse(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-large-hook"
	t.Setenv("QUESTMASTER_SESSION", "")
	t.Setenv("CODEX_THREAD_ID", "")
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", sessionID, "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit","tool_use_id":"call-1"}`), &stderr); err != nil || !handled || stderr.Len() != 0 {
		t.Fatalf("tool_start: handled=%t err=%v stderr=%q", handled, err, stderr.String())
	}
	before, err := state.LoadSessionState(sessionID)
	if err != nil || len(before.Panes["agent"].RunningTools) != 1 {
		t.Fatalf("running tool before tool_end: state=%+v err=%v", before, err)
	}
	// Let the recorded duration exceed the store's one-millisecond floor.
	time.Sleep(2 * time.Millisecond)
	runtime.GC()
	var start, end runtime.MemStats
	runtime.ReadMemStats(&start)
	if handled, err := executeHookFastPath([]string{"--session", sessionID, "codex", "tool_end"}, codexToolEndWithResponse(50<<20), &stderr); err != nil || !handled {
		t.Fatalf("tool_end: handled=%t err=%v", handled, err)
	}
	runtime.ReadMemStats(&end)
	if stderr.Len() != 0 {
		t.Fatalf("tool_end stderr: %s", stderr.String())
	}
	after, err := state.LoadSessionState(sessionID)
	if err != nil {
		t.Fatal(err)
	}
	pane := after.Panes["agent"]
	if pane.Tool != "" || len(pane.RunningTools) != 0 || pane.LastKind != "PostToolUse" {
		t.Fatalf("tool_end did not close running tool: %+v", pane)
	}
	if _, err := os.Stat(filepath.Join(root, sessionID, "hook-errors.log")); !os.IsNotExist(err) {
		t.Fatalf("unexpected hook-errors.log: %v", err)
	}
	durations, err := os.ReadFile(filepath.Join(root, "tool-durations.json"))
	if err != nil || !bytes.Contains(durations, []byte(`"tool":"Edit"`)) {
		t.Fatalf("duration was not recorded: %s, %v", durations, err)
	}
	if allocated := end.TotalAlloc - start.TotalAlloc; allocated > 8<<20 {
		t.Fatalf("50 MiB response allocated %d bytes; want at most 8 MiB", allocated)
	}
}

func TestHookBeyondHardBoundIsDroppedAndLogged(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-too-large-hook"
	t.Setenv("QUESTMASTER_SESSION", "")
	var stderr bytes.Buffer
	_, err := executeHookFastPath([]string{"--session", sessionID, "codex", "tool_end"}, codexToolEndWithResponse(64<<20), &stderr)
	if err != nil {
		t.Fatal(err)
	}
	log := hookErrorLog(t, root, sessionID)
	if !strings.Contains(log, "codex/tool_end") || !strings.Contains(log, "67108864-byte limit") || !strings.Contains(log, "67108865 bytes") {
		t.Fatalf("bound error lacks event and size: %s", log)
	}
	if _, err := os.Stat(filepath.Join(root, sessionID, "state.jsonl")); !os.IsNotExist(err) {
		t.Fatalf("oversized event was recorded: %v", err)
	}
}

func TestHookBridgesAcceptLargeDiscardedResponse(t *testing.T) {
	for _, tc := range []struct {
		name, agent, action, prefix, suffix string
	}{
		{"claude", "claude", "tool_end", `{"tool_response":{"data":"`, `"},"tool_name":"Edit"}`},
		{"pi batch", "pi", "batch", `{"events":[{"action":"tool_execution_end","payload":{"tool_response":{"data":"`, `"},"toolName":"bash"}}]}`},
		{"opencode", "opencode", "event", `{"event":{"type":"session.created","properties":{"tool_response":{"data":"`, `"},"info":{"id":"ses_example"}}}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := setTestStateRoot(t)
			const sessionID = "qm-large-bridge"
			t.Setenv("QUESTMASTER_SESSION", "")
			if tc.agent == "opencode" {
				manifest := state.Manifest{SessionID: sessionID, Agents: []state.AgentManifest{{Name: "opencode", Role: "agent", CLI: "opencode", ResumeID: "ses_example"}}}
				manifest.SetExtra("opencode_session_id", "ses_example")
				if err := state.OpenStore(root).Create(manifest); err != nil {
					t.Fatal(err)
				}
			}
			payload := io.MultiReader(strings.NewReader(tc.prefix), io.LimitReader(repeatedHookByte{value: 'x'}, 2<<20), strings.NewReader(tc.suffix))
			var stderr bytes.Buffer
			if handled, err := executeHookFastPath([]string{"--session", sessionID, tc.agent, tc.action}, payload, &stderr); err != nil || !handled || stderr.Len() != 0 {
				t.Fatalf("hook: handled=%t err=%v stderr=%q", handled, err, stderr.String())
			}
			if events := stateEventLines(t, root, sessionID); len(events) != 1 {
				t.Fatalf("events = %+v", events)
			}
			if _, err := os.Stat(filepath.Join(root, sessionID, "hook-errors.log")); !os.IsNotExist(err) {
				t.Fatalf("unexpected hook-errors.log: %v", err)
			}
		})
	}
}

func TestHookSmallMalformedPayloadStillReachesTolerantHandler(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_SESSION", "")
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-small-malformed", "claude", "tool_end"}, strings.NewReader(`{"tool_name":`), &stderr); err != nil || !handled || stderr.Len() != 0 {
		t.Fatalf("hook: handled=%t err=%v stderr=%q", handled, err, stderr.String())
	}
	if events := stateEventLines(t, root, "qm-small-malformed"); len(events) != 1 || events[0].Action != "tool_end" {
		t.Fatalf("events = %+v", events)
	}
}

// hookBudget is what these tests allow a bounded hook: the 800 ms deadline
// plus room for a loaded test machine. The unbounded hooks they replace
// waited 5 s or 10 s.
const hookBudget = 2 * time.Second

func hookErrorLog(t *testing.T, root, sessionID string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, sessionID, "hook-errors.log"))
	if err != nil {
		t.Fatalf("read hook-errors.log: %v", err)
	}
	return string(data)
}

func stateEventLines(t *testing.T, root, sessionID string) []state.StateEvent {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, sessionID, "state.jsonl"))
	if err != nil {
		t.Fatalf("read state.jsonl: %v", err)
	}
	var events []state.StateEvent
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		var ev state.StateEvent
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			t.Fatalf("decode state.jsonl line %q: %v", line, err)
		}
		events = append(events, ev)
	}
	return events
}

func productionHookRunner(t *testing.T, root string) *HookRunner {
	t.Helper()
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("TMUX_PANE", "")
	return newHookRunner(state.OpenStore(root), &tmuxEnvStub{})
}

// A tmux call that hangs must not hold the agent: the hook gives up at its
// deadline and records why in the session's hook-errors.log.
func TestHookTmuxCallStopsAtDeadlineAndIsLogged(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-tmux-deadline"
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte("#!/bin/sh\nexec sleep 10\n"), 0o755); err != nil {
		t.Fatalf("write fake tmux: %v", err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	r := productionHookRunner(t, root)
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: sessionID, Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	// A private socket path: even if the fake were not found, a real tmux
	// would only reach this absent server.
	r.TmuxClient = tmux.NewClient(tmux.SocketServer(filepath.Join(t.TempDir(), "absent.sock")))

	start := time.Now()
	runHookWithStdin(r, "claude", "working", sessionID, map[string]interface{}{"session_id": "claude-session-1"})
	if elapsed := time.Since(start); elapsed > hookBudget {
		t.Fatalf("hook took %s with a hanging tmux, want under %s", elapsed, hookBudget)
	}
	if log := hookErrorLog(t, root, sessionID); !strings.Contains(log, "set tmux env") {
		t.Fatalf("hook-errors.log does not name the tmux failure:\n%s", log)
	}
}

// A held state lock must not hold the agent either: the hook polls for the
// lock until its deadline, then skips the state write and logs it.
func TestHookStateLockTimeoutSkipsWriteAndLogs(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-lock-deadline"
	r := productionHookRunner(t, root)
	if err := os.MkdirAll(filepath.Join(root, sessionID), 0o700); err != nil {
		t.Fatalf("mkdir session state: %v", err)
	}
	lock, err := os.OpenFile(filepath.Join(root, sessionID, "state.json.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("open state lock: %v", err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatalf("hold state lock: %v", err)
	}
	// Let an unbounded hook finish eventually so a failing run ends.
	release := time.AfterFunc(5*time.Second, func() { _ = syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) })
	defer release.Stop()

	start := time.Now()
	runHookWithStdin(r, "claude", "working", sessionID, nil)
	if elapsed := time.Since(start); elapsed > hookBudget {
		t.Fatalf("hook waited %s for a held state lock, want under %s", elapsed, hookBudget)
	}
	if _, err := os.Stat(filepath.Join(root, sessionID, "state.json")); !os.IsNotExist(err) {
		t.Fatalf("state.json written without the lock: stat err = %v", err)
	}
	if log := hookErrorLog(t, root, sessionID); !strings.Contains(log, "state lock") {
		t.Fatalf("hook-errors.log does not name the lock timeout:\n%s", log)
	}
}

// A hook that started before the pane's last event must not move the pane
// back: an older "done" that loses the race to a newer "working" leaves the
// pane working. Its event still reaches state.jsonl.
func TestHookOlderTransitionDoesNotRegressNewerState(t *testing.T) {
	base := time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)
	newer, older := base.Add(2*time.Second), base.Add(time.Second)
	openCode := func(eventType string, props map[string]interface{}) map[string]interface{} {
		props["sessionID"] = "ses_order"
		return map[string]interface{}{"event": map[string]interface{}{"type": eventType, "properties": props}}
	}
	type step struct {
		action  string
		payload interface{}
	}
	for _, tc := range []struct {
		name        string
		agent       string
		seed        *step
		newer       step
		older       step
		olderLogged string
	}{
		{
			name: "claude", agent: "claude",
			newer:       step{action: "working"},
			older:       step{action: "done", payload: map[string]interface{}{"last_assistant_message": "Earlier turn finished."}},
			olderLogged: "done",
		},
		{
			name: "codex", agent: "codex",
			newer:       step{action: "working"},
			older:       step{action: "done", payload: map[string]interface{}{"last_assistant_message": "Earlier turn finished."}},
			olderLogged: "done",
		},
		{
			name: "pi", agent: "pi",
			newer:       step{action: "agent_start", payload: map[string]interface{}{}},
			older:       step{action: "agent_end", payload: map[string]interface{}{}},
			olderLogged: "agent_end",
		},
		{
			name: "opencode", agent: "opencode",
			seed:        &step{action: "event", payload: openCode("session.created", map[string]interface{}{})},
			newer:       step{action: "event", payload: openCode("session.status", map[string]interface{}{"status": map[string]interface{}{"type": "busy"}})},
			older:       step{action: "event", payload: openCode("session.idle", map[string]interface{}{})},
			olderLogged: "session.idle",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := setTestStateRoot(t)
			sessionID := "qm-order-" + tc.name
			r := productionHookRunner(t, root)
			if tc.seed != nil {
				r.Now = func() time.Time { return base }
				runHookWithStdin(r, tc.agent, tc.seed.action, sessionID, tc.seed.payload)
			}
			r.Now = func() time.Time { return newer }
			runHookWithStdin(r, tc.agent, tc.newer.action, sessionID, tc.newer.payload)
			r.Now = func() time.Time { return older }
			runHookWithStdin(r, tc.agent, tc.older.action, sessionID, tc.older.payload)

			ss, err := state.LoadSessionStateAt(root, sessionID)
			if err != nil || ss == nil {
				t.Fatalf("load state: %v (state %v)", err, ss)
			}
			pane := ss.Panes["agent"]
			if pane.State != "working" || !pane.LastEvent.Equal(newer) {
				t.Fatalf("pane after an older %s = state %q last_event %s, want working at %s", tc.older.action, pane.State, pane.LastEvent, newer)
			}
			events := stateEventLines(t, root, sessionID)
			if last := events[len(events)-1]; last.Action != tc.olderLogged {
				t.Fatalf("last logged event = %q, want the older %q still logged", last.Action, tc.olderLogged)
			}
		})
	}
}

// Parallel tool calls are the common reordering: an older PreToolUse that
// loses the race still records its running tool and its chat action, but it
// does not take the plate back to an earlier tool.
func TestHookOlderToolStartKeepsItsRecordsButNotThePlate(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-order-tools"
	base := time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)
	r := productionHookRunner(t, root)
	r.Now = func() time.Time { return base }
	runHookWithStdin(r, "claude", "working", sessionID, nil)
	r.Now = func() time.Time { return base.Add(2 * time.Second) }
	runHookWithStdin(r, "claude", "tool_start", sessionID, map[string]interface{}{
		"tool_name": "Read", "tool_use_id": "toolu_newer", "tool_input": map[string]interface{}{"file_path": "/repo/newer.go"},
	})
	r.Now = func() time.Time { return base.Add(time.Second) }
	runHookWithStdin(r, "claude", "tool_start", sessionID, map[string]interface{}{
		"tool_name": "Bash", "tool_use_id": "toolu_older", "tool_input": map[string]interface{}{"command": "go test ./..."},
	})

	ss, err := state.LoadSessionStateAt(root, sessionID)
	if err != nil || ss == nil {
		t.Fatalf("load state: %v", err)
	}
	pane := ss.Panes["agent"]
	if pane.Activity != "Read: newer.go" || pane.Tool != "Read" {
		t.Fatalf("plate = activity %q tool %q, want the newer Read", pane.Activity, pane.Tool)
	}
	if len(pane.RunningTools) != 2 {
		t.Fatalf("running tools = %+v, want both calls", pane.RunningTools)
	}
	events := stateEventLines(t, root, sessionID)
	if got := chatTextFor(events[len(events)-1], "action"); got != "Bash" {
		t.Fatalf("older tool_start chat action = %q, want Bash", got)
	}
}

// state.json is rebuilt by the next hook, so a file that no longer decodes is
// moved aside once and the session carries on instead of failing every hook.
func TestHookCorruptStateIsMovedAsideOnce(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-corrupt-state"
	r := productionHookRunner(t, root)
	dir := filepath.Join(root, sessionID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	corrupt := []byte(`{"session_id":"qm-corrupt-state","panes":`)
	if err := os.WriteFile(filepath.Join(dir, "state.json"), corrupt, 0o600); err != nil {
		t.Fatalf("write corrupt state: %v", err)
	}

	runHookWithStdin(r, "claude", "working", sessionID, nil)
	runHookWithStdin(r, "claude", "tool_start", sessionID, map[string]interface{}{"tool_name": "Read"})

	ss, err := state.LoadSessionStateAt(root, sessionID)
	if err != nil || ss == nil {
		t.Fatalf("state after recovery: %v (state %v)", err, ss)
	}
	if got := ss.Panes["agent"].State; got != "working" {
		t.Fatalf("state after recovery = %q, want working", got)
	}
	aside, err := filepath.Glob(filepath.Join(dir, "state.json.corrupt-*"))
	if err != nil || len(aside) != 1 {
		t.Fatalf("corrupt copies = %v (err %v), want exactly one", aside, err)
	}
	if kept, err := os.ReadFile(aside[0]); err != nil || string(kept) != string(corrupt) {
		t.Fatalf("corrupt copy = %q (err %v), want the original bytes", kept, err)
	}
	if log := hookErrorLog(t, root, sessionID); !strings.Contains(log, filepath.Base(aside[0])) {
		t.Fatalf("hook-errors.log does not name the moved file:\n%s", log)
	}
}

// Activity is stored and shown; a credential typed into a command must not
// end up in it. Redaction is best effort: it covers Authorization headers and
// secret-named assignments.
func TestHookRedactsCredentialsFromActivity(t *testing.T) {
	const (
		bearer   = "example-bearer-value-456"
		assigned = "example-secret-value-123"
	)
	commands := []string{
		`curl -H "Authorization: Bearer ` + bearer + `" https://example.com`,
		`cd repo && GITHUB_TOKEN=` + assigned + ` gh api /user`,
	}
	for _, tc := range []struct {
		agent, action string
		payload       func(command string) map[string]interface{}
	}{
		{"claude", "tool_start", func(c string) map[string]interface{} {
			return map[string]interface{}{"tool_name": "Bash", "tool_input": map[string]interface{}{"command": c}}
		}},
		{"codex", "tool_start", func(c string) map[string]interface{} {
			return map[string]interface{}{"tool_name": "Bash", "tool_input": map[string]interface{}{"command": c}}
		}},
		{"pi", "tool_execution_start", func(c string) map[string]interface{} {
			return map[string]interface{}{"toolName": "bash", "args": map[string]interface{}{"command": c}}
		}},
	} {
		t.Run(tc.agent, func(t *testing.T) {
			root := setTestStateRoot(t)
			sessionID := "qm-redact-" + tc.agent
			r := productionHookRunner(t, root)
			for _, command := range commands {
				runHookWithStdin(r, tc.agent, tc.action, sessionID, tc.payload(command))
				for _, name := range []string{"state.json", "state.jsonl"} {
					data, err := os.ReadFile(filepath.Join(root, sessionID, name))
					if err != nil {
						t.Fatalf("read %s: %v", name, err)
					}
					for _, secret := range []string{bearer, assigned} {
						if strings.Contains(string(data), secret) {
							t.Fatalf("%s keeps %q after %q:\n%s", name, secret, command, data)
						}
					}
				}
			}
		})
	}
}

// Session state and the hook error log hold activity text; only the user
// may read them.
func TestHookStateFilesArePrivate(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-private-files"
	r := productionHookRunner(t, root)
	runHookWithStdin(r, "claude", "working", sessionID, nil)
	runHookWithStdin(r, "claude", "no-such-action", sessionID, nil)
	for _, name := range []string{"state.json", "state.jsonl", "hook-errors.log"} {
		info, err := os.Stat(filepath.Join(root, sessionID, name))
		if err != nil {
			t.Fatalf("stat %s: %v", name, err)
		}
		if mode := info.Mode().Perm(); mode != 0o600 {
			t.Errorf("%s mode = %o, want 600", name, mode)
		}
	}
}

// Agents discard a hook's stderr, so every handler error also goes to the
// session's hook-errors.log, tagged with the event that hit it.
func TestHookHandlerErrorsGoToHookErrorLog(t *testing.T) {
	root := setTestStateRoot(t)
	const sessionID = "qm-error-log"
	r := productionHookRunner(t, root)
	stderr := runHookWithStdin(r, "claude", "no-such-action", sessionID, nil)
	if !strings.Contains(stderr, "unknown action") {
		t.Fatalf("stderr = %q, want the unknown-action warning", stderr)
	}
	log := hookErrorLog(t, root, sessionID)
	if !strings.Contains(log, "claude/no-such-action") || !strings.Contains(log, "unknown action") {
		t.Fatalf("hook-errors.log = %q, want the tagged warning", log)
	}
}
