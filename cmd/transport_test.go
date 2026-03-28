//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// sendRunner simulates a tmux environment for send tests.
// Supports display-message (session name), list-panes, send-keys, and idle check.
func sendRunner(sessionName string, paneLayout string) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
			// Check if this is an idle check (-t target -p #{pane_in_mode})
			for _, a := range args {
				if a == "#{pane_in_mode}" {
					return "0", nil // idle
				}
				if a == "#{session_name}" {
					return sessionName, nil
				}
			}
			return sessionName, nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return paneLayout, nil
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

// ---------------------------------------------------------------------------
// send command tests
// ---------------------------------------------------------------------------

func TestSendCmd_ByRole(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-test", "test", "/tmp", "regular")

	// Standard sidebar layout: window 0 has codex, window 1 has party-cli + claude + shell
	out := runCmd(t, store, sendRunner("party-test", "1 0 party-cli\n1 1 claude\n1 2 shell"),
		"send", "--role", "claude", "--session", "party-test", "hello claude")
	// Success = no output, no error
	_ = out
}

func TestSendCmd_AutoDiscover(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-test", "test", "/tmp", "regular")

	// No --session flag — auto-discover from tmux
	out := runCmd(t, store, sendRunner("party-test", "1 1 claude"),
		"send", "--role", "claude", "hello")
	_ = out
}

func TestSendCmd_MasterBlocksCodex(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "orch", "/tmp", "master")

	_, err := runCmdErr(t, store, sendRunner("party-master", "0 0 codex"),
		"send", "--role", "codex", "--session", "party-master", "hello")
	if err == nil {
		t.Fatal("expected error sending to codex pane in master session")
	}
	if !strings.Contains(err.Error(), "master") {
		t.Fatalf("expected master-related error, got: %v", err)
	}
}

func TestSendCmd_RoleNotFound(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-test", "test", "/tmp", "regular")

	_, err := runCmdErr(t, store, sendRunner("party-test", "1 0 shell"),
		"send", "--role", "codex", "--session", "party-test", "hello")
	if err == nil {
		t.Fatal("expected error for missing role")
	}
}

func TestSendCmd_MissingMessage(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, sendRunner("party-test", ""),
		"send", "--role", "claude", "--session", "party-test")
	if err == nil {
		t.Fatal("expected error for missing message arg")
	}
}

// ---------------------------------------------------------------------------
// codex-status write tests
// ---------------------------------------------------------------------------

func TestCodexStatusWrite_Basic(t *testing.T) {
	t.Parallel()

	// Use a custom TMPDIR so codex-status writes to a known location
	tmpDir := t.TempDir()
	sessionID := "party-status-test"
	runtimeDir := filepath.Join(tmpDir, sessionID)
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// We need the command to resolve the runtime dir to our temp location.
	// Override os.TempDir via setting session explicitly and pre-creating the dir.
	store := setupStore(t)
	// The command uses os.TempDir() to build runtime dir, so we need to mock.
	// Instead, let's test with an explicit --session and check the right dir.
	// Actually, codex-status write uses filepath.Join(os.TempDir(), sessionID).
	// We can't easily override os.TempDir, but we CAN verify the JSON structure
	// by reading the file from the actual temp location.

	runner := sendRunner(sessionID, "")
	runCmd(t, store, runner, "codex-status", "write",
		"--session", sessionID,
		"--target", "main",
		"--mode", "review",
		"working")

	statusFile := filepath.Join(os.TempDir(), sessionID, "codex-status.json")
	defer os.RemoveAll(filepath.Join(os.TempDir(), sessionID))

	data, err := os.ReadFile(statusFile)
	if err != nil {
		t.Fatalf("read status file: %v", err)
	}

	var status map[string]string
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("unmarshal status: %v", err)
	}

	if status["state"] != "working" {
		t.Fatalf("expected state=working, got: %s", status["state"])
	}
	if status["target"] != "main" {
		t.Fatalf("expected target=main, got: %s", status["target"])
	}
	if status["mode"] != "review" {
		t.Fatalf("expected mode=review, got: %s", status["mode"])
	}
	if status["started_at"] == "" {
		t.Fatal("expected started_at for working state")
	}
}

func TestCodexStatusWrite_ErrorState(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "party-status-err"

	runner := sendRunner(sessionID, "")
	runCmd(t, store, runner, "codex-status", "write",
		"--session", sessionID,
		"--error", "pane busy",
		"error")

	statusFile := filepath.Join(os.TempDir(), sessionID, "codex-status.json")
	defer os.RemoveAll(filepath.Join(os.TempDir(), sessionID))

	data, err := os.ReadFile(statusFile)
	if err != nil {
		t.Fatalf("read status file: %v", err)
	}

	var status map[string]string
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("unmarshal status: %v", err)
	}

	if status["state"] != "error" {
		t.Fatalf("expected state=error, got: %s", status["state"])
	}
	if status["error"] != "pane busy" {
		t.Fatalf("expected error='pane busy', got: %s", status["error"])
	}
	if status["finished_at"] == "" {
		t.Fatal("expected finished_at for error state")
	}
}

// ---------------------------------------------------------------------------
// session-env tests
// ---------------------------------------------------------------------------

func TestSessionEnv_Output(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	runner := sendRunner("party-env-test", "")
	out := runCmd(t, store, runner, "session-env")

	if !strings.Contains(out, "SESSION_NAME=") {
		t.Fatalf("expected SESSION_NAME in output, got: %s", out)
	}
	if !strings.Contains(out, "party-env-test") {
		t.Fatalf("expected session ID in output, got: %s", out)
	}
	if !strings.Contains(out, "STATE_DIR=") {
		t.Fatalf("expected STATE_DIR in output, got: %s", out)
	}
	if !strings.Contains(out, "STATE_FILE=") {
		t.Fatalf("expected STATE_FILE in output, got: %s", out)
	}
	if !strings.Contains(out, "RUNTIME_DIR=") {
		t.Fatalf("expected RUNTIME_DIR in output, got: %s", out)
	}

	// Cleanup runtime dir created by session-env
	defer os.RemoveAll(filepath.Join(os.TempDir(), "party-env-test"))
}

func TestSessionEnv_NotPartySession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	runner := sendRunner("dev", "")
	_, err := runCmdErr(t, store, runner, "session-env")
	if err == nil {
		t.Fatal("expected error for non-party session")
	}
}
