package cmd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestHookAgentOwnership(t *testing.T) {
	hooks := []struct {
		agent, action, payload, wantState string
	}{
		{"claude", "done", `{"last_assistant_message":"Nested answer"}`, "done"},
		{"codex", "done", `{"last_assistant_message":"Nested answer"}`, "done"},
		{"pi", "agent_end", `{"errorMessage":"Example provider error"}`, "blocked"},
		{"pi", "session_shutdown", `{}`, "stopped"},
		{"pi", "batch", `{"events":[{"action":"agent_end","payload":{"errorMessage":"Example provider error"}},{"action":"session_shutdown","payload":{}}]}`, "stopped"},
		{"opencode", "event", `{"version":"1.17.11","event":{"type":"session.status","properties":{"status":{"type":"busy"}}}}`, "working"},
	}
	for _, path := range []string{"fast", "cobra"} {
		for _, owner := range []string{"claude", "codex", "pi", "opencode"} {
			for _, hook := range hooks {
				t.Run(path+"/"+owner+"/"+hook.agent+"/"+hook.action, func(t *testing.T) {
					root := setTestStateRoot(t)
					t.Setenv("QUESTMASTER_TMUX_SERVER", "questmaster")
					t.Setenv("QUESTMASTER_TMUX_LABEL", "")
					if err := os.Unsetenv("QUESTMASTER_TMUX_LABEL"); err != nil {
						t.Fatal(err)
					}
					t.Setenv("TMUX_PANE", "%7")
					t.Setenv("CODEX_THREAD_ID", "")
					const id = "qm-owner"
					store := state.OpenStore(root)
					if err := store.Create(state.Manifest{
						SessionID: id, TmuxServer: "questmaster",
						Agents: []state.AgentManifest{{Name: owner, Role: "agent"}},
					}); err != nil {
						t.Fatal(err)
					}
					if err := state.UpdateAndLogAt(root, id, &state.StateEvent{Agent: owner, Action: "working"}, func(ss *state.SessionState) bool {
						pane := state.PaneState{Role: "agent", Agent: owner, State: "working", Activity: "Managed task"}
						if owner == "opencode" {
							pane.OpenCodeSessionID = "ses_example"
						}
						ss.Panes["agent"] = pane
						return true
					}); err != nil {
						t.Fatal(err)
					}
					files := []string{state.SessionStatePath(root, id), state.SessionStateLogPath(root, id), filepath.Join(root, id+".json")}
					before := make([][]byte, len(files))
					for i, file := range files {
						var err error
						before[i], err = os.ReadFile(file)
						if err != nil {
							t.Fatal(err)
						}
					}
					args := []string{"--session", id, hook.agent, hook.action}
					var stderr bytes.Buffer
					if path == "fast" {
						if handled, err := executeHookFastPath(args, strings.NewReader(hook.payload), &stderr); err != nil || !handled {
							t.Fatalf("hook handled=%t err=%v", handled, err)
						}
					} else {
						cmd := newHookCmd(store, tmux.NewClient(allPassRunner()))
						cmd.SetArgs(args)
						cmd.SetIn(strings.NewReader(hook.payload))
						cmd.SetErr(&stderr)
						if err := cmd.Execute(); err != nil {
							t.Fatal(err)
						}
					}
					if stderr.Len() != 0 {
						t.Fatalf("hook stderr = %q", stderr.String())
					}
					if owner == hook.agent {
						ss, err := state.LoadSessionStateAt(root, id)
						if err != nil {
							t.Fatal(err)
						}
						if pane := ss.Panes["agent"]; pane.Agent != owner || pane.State != hook.wantState {
							t.Fatalf("owner hook pane = %+v, want %s/%s", pane, owner, hook.wantState)
						}
						log, err := os.ReadFile(files[1])
						if err != nil || bytes.Equal(log, before[1]) {
							t.Fatalf("owner hook did not append an event: %v", err)
						}
						return
					}
					for i, file := range files {
						after, err := os.ReadFile(file)
						if err != nil {
							t.Fatal(err)
						}
						if !bytes.Equal(before[i], after) {
							t.Errorf("foreign %s hook changed %s", hook.agent, filepath.Base(file))
						}
					}
				})
			}
		}
	}
}

func TestHookEnvAbsentMakesNoWrites(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_TMUX_SERVER", "")
	if err := os.Unsetenv("QUESTMASTER_TMUX_SERVER"); err != nil {
		t.Fatal(err)
	}
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: "qm-old", TmuxServer: "default"}); err != nil {
		t.Fatal(err)
	}
	mustSessionStateDir(t, root, "qm-old")
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-old", "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit"}`), &stderr); err != nil || !handled {
		t.Fatalf("hook handled=%t err=%v stderr=%q", handled, err, stderr.String())
	}
	if _, err := os.Stat(state.SessionStatePath(root, "qm-old")); !os.IsNotExist(err) {
		t.Fatal(err)
	}
}

func TestHookStaleOriginMakesNoWrites(t *testing.T) {
	for _, path := range []string{"fast", "cobra"} {
		t.Run(path, func(t *testing.T) {
			root := setTestStateRoot(t)
			t.Setenv("QUESTMASTER_TMUX_SERVER", "default")
			store := state.OpenStore(root)
			if err := store.Create(state.Manifest{SessionID: "qm-new", TmuxServer: "questmaster"}); err != nil {
				t.Fatal(err)
			}
			mustSessionStateDir(t, root, "qm-new")
			payload := strings.NewReader(`{"tool_name":"Edit"}`)
			var stderr bytes.Buffer
			if path == "fast" {
				if handled, err := executeHookFastPath([]string{"--session", "qm-new", "codex", "tool_start"}, payload, &stderr); err != nil || !handled {
					t.Fatalf("hook handled=%t err=%v", handled, err)
				}
			} else {
				cmd := newHookCmd(store, tmux.NewClient(allPassRunner()))
				cmd.SetArgs([]string{"--session", "qm-new", "codex", "tool_start"})
				cmd.SetIn(payload)
				cmd.SetErr(&stderr)
				if err := cmd.Execute(); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := os.Stat(state.SessionStatePath(root, "qm-new")); !os.IsNotExist(err) {
				t.Fatalf("stale hook wrote state: %v", err)
			}
			if _, err := os.Stat(state.SessionStateLogPath(root, "qm-new")); !os.IsNotExist(err) {
				t.Fatalf("stale hook wrote an event: %v", err)
			}
			if !strings.Contains(stderr.String(), "invalid tmux origin") {
				t.Fatalf("diagnostic = %q", stderr.String())
			}
			if lines := strings.Split(strings.TrimSpace(hookErrorLog(t, root, "qm-new")), "\n"); len(lines) != 1 || !strings.Contains(lines[0], "invalid tmux origin") {
				t.Fatalf("hook error lines = %q", lines)
			}
		})
	}
}

func TestHookMissingOwnershipMakesNoWrites(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "invalid!")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("TMUX_PANE", "")
	t.Setenv("QUESTMASTER_TMUX_SERVER", "")
	if err := os.Unsetenv("QUESTMASTER_TMUX_SERVER"); err != nil {
		t.Fatal(err)
	}
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: "qm-old"}); err != nil {
		t.Fatal(err)
	}
	mustSessionStateDir(t, root, "qm-old")
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-old", "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit"}`), &stderr); err != nil || !handled {
		t.Fatalf("hook handled=%t err=%v", handled, err)
	}
	if _, err := os.Stat(state.SessionStatePath(root, "qm-old")); !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimSpace(hookErrorLog(t, root, "qm-old")), "\n"); len(lines) != 1 || !strings.Contains(lines[0], "invalid tmux origin") {
		t.Fatalf("hook error lines = %q", lines)
	}
}

func TestHookNamedStopsAfterRouterSetupError(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "invalid!")
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("QUESTMASTER_TMUX_SERVER", "questmaster")
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: "qm-new", TmuxServer: "questmaster"}); err != nil {
		t.Fatal(err)
	}
	mustSessionStateDir(t, root, "qm-new")
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-new", "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit"}`), &stderr); err != nil || !handled {
		t.Fatalf("hook handled=%t err=%v", handled, err)
	}
	if _, err := os.Stat(state.SessionStatePath(root, "qm-new")); !os.IsNotExist(err) {
		t.Fatalf("named hook wrote state: %v", err)
	}
	if lines := strings.Split(strings.TrimSpace(hookErrorLog(t, root, "qm-new")), "\n"); len(lines) != 1 || !strings.Contains(lines[0], "route") {
		t.Fatalf("hook error lines = %q", lines)
	}
}

func TestHookWritesRecipientServer(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_TMUX_SERVER", "questmaster")
	t.Setenv("CODEX_THREAD_ID", "example-thread")
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: "qm-new", TmuxServer: "questmaster", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	mustSessionStateDir(t, root, "qm-new")
	legacyCalls, namedCalls := 0, 0
	runner := func(calls *int) *mockRunner {
		return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			if args[0] == "set-environment" {
				(*calls)++
			}
			return "", nil
		}}
	}
	legacy, named := tmux.NewClient(runner(&legacyCalls)), tmux.NewClient(runner(&namedCalls))
	routes := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	r := newHookRunner(store, legacy)
	r.initialTmuxClient = legacy
	r.TmuxRouter = routes
	var stderr bytes.Buffer
	runHook(r, hookOptions{agent: "codex", action: "tool_start", session: "qm-new", stdin: []byte(`{"tool_name":"Edit","tool_use_id":"call-1"}`)}, &stderr)
	if legacyCalls != 0 || namedCalls == 0 {
		t.Fatalf("tmux writes: legacy=%d named=%d stderr=%q", legacyCalls, namedCalls, stderr.String())
	}
}

// mustSessionStateDir creates the session's state directory, which a live
// session always has: hook errors are logged only into an existing directory
// (a deleted session's late hooks must not recreate it).
func mustSessionStateDir(t *testing.T, root, id string) {
	t.Helper()
	if err := os.MkdirAll(state.SessionStateDir(root, id), 0o700); err != nil {
		t.Fatal(err)
	}
}
