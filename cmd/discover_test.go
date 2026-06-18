//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
)

// displayRunner returns a mock that reports a session name for display-message
// and responds to has-session/list-sessions.
func displayRunner(sessionName string, live ...string) *mockRunner {
	liveSet := make(map[string]bool)
	for _, s := range live {
		liveSet[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
			// Distinguish session-name query from pane idle check.
			// Idle check uses -t <target> -p #{pane_in_mode}.
			for _, a := range args {
				if a == "#{pane_in_mode}" {
					return "0", nil // pane idle
				}
			}
			return sessionName, nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if liveSet[target] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
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

	client := tmux.NewClient(displayRunner("qm-other"))
	got, err := discoverSession(t.Context(), client)
	if err != nil {
		t.Fatalf("discoverSession: %v", err)
	}
	if got != "qm-current" {
		t.Fatalf("discoverSession = %q, want qm-current", got)
	}
}

// ---------------------------------------------------------------------------
// broadcast auto-discover tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_AutoDiscover_Success(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	// Omit master-id — should auto-discover via display-message
	out := runCmd(t, store, displayRunner("qm-master", "qm-w1"), "broadcast", "hello all")
	var got struct {
		MasterID   string `json:"master_id"`
		Registered int    `json:"registered"`
		Delivered  int    `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" || got.Registered != 1 || got.Delivered != 1 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
	}
}

func TestBroadcastCmd_AutoDiscover_NotMaster(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-regular", "regular", "/tmp", "regular")

	// Auto-discover should fail because session is not a master
	_, err := runCmdErr(t, store, displayRunner("qm-regular"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

func TestBroadcastCmd_AutoDiscover_NotQuestmaster(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)

	_, err := runCmdErr(t, store, displayRunner("dev"), "broadcast", "hello")
	if err == nil {
		t.Fatal("expected error for non-questmaster session")
	}
}

// ---------------------------------------------------------------------------
// QUESTMASTER_SESSION env var override tests
// ---------------------------------------------------------------------------

func TestBroadcastCmd_SessionOverride(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	// displayRunner returns "qm-other" but QUESTMASTER_SESSION should take precedence
	out := runCmd(t, store, displayRunner("qm-other", "qm-w1"), "broadcast", "hello all")
	var got struct {
		MasterID   string `json:"master_id"`
		Registered int    `json:"registered"`
		Delivered  int    `json:"delivered"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("broadcast output is not JSON: %v\n%s", err, out)
	}
	if got.MasterID != "qm-master" || got.Registered != 1 || got.Delivered != 1 {
		t.Fatalf("broadcast JSON mismatch: %#v", got)
	}
}

// ---------------------------------------------------------------------------
// workers auto-discover tests
// ---------------------------------------------------------------------------

func TestWorkersCmd_AutoDiscover_Success(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	out := runCmd(t, store, displayRunner("qm-master", "qm-w1"), "workers")
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

	_, err := runCmdErr(t, store, displayRunner("qm-regular"), "workers")
	if err == nil {
		t.Fatal("expected error for non-master session")
	}
}

// ---------------------------------------------------------------------------
// report auto-discover tests
// ---------------------------------------------------------------------------

func TestReportCmd_AutoDiscover_Success(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	// Omit session-id — should auto-discover as qm-w1
	out := runCmd(t, store, displayRunner("qm-w1", "qm-master"), "report", "done: fixed it")
	var got struct {
		SessionID string `json:"session_id"`
		Reported  bool   `json:"reported"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("report output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-w1" || !got.Reported {
		t.Fatalf("report JSON mismatch: %#v", got)
	}
}

func TestReportCmd_AutoDiscover_NotQuestmaster(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)

	_, err := runCmdErr(t, store, displayRunner("dev"), "report", "hello")
	if err == nil {
		t.Fatal("expected error for non-questmaster session")
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
