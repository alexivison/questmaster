package cmd

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestHookEnvAbsentIsLegacy(t *testing.T) {
	root := setTestStateRoot(t)
	t.Setenv("QUESTMASTER_TMUX_SERVER", "")
	if err := os.Unsetenv("QUESTMASTER_TMUX_SERVER"); err != nil {
		t.Fatal(err)
	}
	store := state.OpenStore(root)
	if err := store.Create(state.Manifest{SessionID: "qm-old", TmuxServer: "default"}); err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-old", "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit"}`), &stderr); err != nil || !handled {
		t.Fatalf("hook handled=%t err=%v stderr=%q", handled, err, stderr.String())
	}
	if _, err := os.Stat(state.SessionStatePath(root, "qm-old")); err != nil {
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
			if !strings.Contains(stderr.String(), "stale") {
				t.Fatalf("diagnostic = %q", stderr.String())
			}
			if lines := strings.Split(strings.TrimSpace(hookErrorLog(t, root, "qm-new")), "\n"); len(lines) != 1 || !strings.Contains(lines[0], "stale tmux origin") {
				t.Fatalf("hook error lines = %q", lines)
			}
		})
	}
}

func TestHookLegacyContinuesAfterRouterSetupError(t *testing.T) {
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
	var stderr bytes.Buffer
	if handled, err := executeHookFastPath([]string{"--session", "qm-old", "codex", "tool_start"}, strings.NewReader(`{"tool_name":"Edit"}`), &stderr); err != nil || !handled {
		t.Fatalf("hook handled=%t err=%v", handled, err)
	}
	if _, err := os.Stat(state.SessionStatePath(root, "qm-old")); err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimSpace(hookErrorLog(t, root, "qm-old")), "\n"); len(lines) != 1 || !strings.Contains(lines[0], "route") {
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
