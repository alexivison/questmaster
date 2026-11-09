//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

const (
	testCallerSocket = "/tmp/qm-cmd-test/tmux.sock"
	testCallerPane   = "%1"
)

// displayRunner puts the test process in pane testCallerPane of the mock's
// server, reports sessionName as that pane's session and responds to
// has-session/list-sessions.
func displayRunner(t *testing.T, sessionName string, live ...string) *mockRunner {
	t.Helper()
	t.Setenv("TMUX", testCallerSocket+",1,0")
	t.Setenv("TMUX_PANE", testCallerPane)
	liveSet := make(map[string]bool)
	for _, s := range live {
		liveSet[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
			if args[2] == testCallerPane && args[len(args)-1] == "#{socket_path}\t#{pane_id}\t#{session_name}" {
				return testCallerSocket + "\t" + testCallerPane + "\t" + sessionName, nil
			}
			return livePaneDisplay(args), nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if liveSet[exactSession(target)] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			}
			return strings.Join(live, "\n"), nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 agent", nil
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "captured", nil
		}
		return "", nil
	}}
}

func TestDiscoverSessionPrefersQuestmasterSessionEnv(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-current")
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	createManifest(t, store, "qm-current", "master", "/tmp", "")

	client := tmux.NewClient(displayRunner(t, "qm-other"))
	got, err := discoverSession(t.Context(), client)
	if err != nil {
		t.Fatalf("discoverSession: %v", err)
	}
	if got != "qm-current" {
		t.Fatalf("discoverSession = %q, want qm-current", got)
	}
}

func TestDiscoverIgnoresForeignTMUX(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	t.Setenv("TMUX", "/tmp/foreign.sock,1,0")
	t.Setenv("TMUX_PANE", "%1")
	store := setupStore(t)
	createManifest(t, store, "qm-current", "master", "/tmp", "")
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return "/tmp/managed.sock\t%1\tqm-current", nil
		}
		return "", nil
	}}
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(runner)}, func() string { return "default" }, nil)
	if got, err := discoverSessionRouted(t.Context(), store, router); err == nil {
		t.Fatalf("discovered %q through foreign TMUX", got)
	}
}

// ---------------------------------------------------------------------------
// workers auto-discover tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_AutoDiscover_Success(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	out := runCmd(t, store, displayRunner(t, "qm-master", "qm-w1"), "workers")
	var got workersJSONOutput
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("workers output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" || len(got.Workers) != 1 || got.Workers[0].SessionID != "qm-w1" {
		t.Fatalf("workers JSON mismatch: %#v", got)
	}
}

func TestWorkersCmd_AutoDiscover_NotMaster(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-regular", "regular", "/tmp", "regular")
	if err := store.Update("qm-regular", func(m *state.Manifest) { m.SetExtra("parent_session", "qm-parent") }); err != nil {
		t.Fatal(err)
	}

	_, err := runCmdErr(t, store, displayRunner(t, "qm-regular"), "workers")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

// ---------------------------------------------------------------------------
// start --attach tests (cobra wiring only — attach itself needs tmux)
// ---------------------------------------------------------------------------

func TestStartCmd_AttachFlag_Accepted(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	// Verify --attach is accepted by cobra. The actual attach needs a live tmux
	// server, so we tolerate runtime errors — only flag-parsing failures are bugs.
	// With TMUX unset, attachSession runs the real `tmux attach-session` against
	// the default server. Setting TMUX routes the attach through the injected client.
	t.Setenv("TMUX", "test-tmux,0,0")
	_, err := runCmdErr(t, store, allPassRunner(), "start", "--cwd", cwd, "--attach", "test-title")
	if err != nil && strings.Contains(err.Error(), "unknown flag") {
		t.Fatalf("--attach flag not recognized by cobra: %v", err)
	}
}

func TestStartCmd_NoAttachByDefault(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	// Without --attach, session starts without attach attempt
	out := runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "test-title")
	var got struct {
		SessionID string `json:"session_id"`
		Cwd       string `json:"cwd"`
		Title     string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("start output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.Cwd != cwd || got.Title != "test-title" {
		t.Fatalf("start JSON mismatch: %#v", got)
	}
}
