//go:build linux || darwin

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

func TestStateLogReadsStateJSONL(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-state-log", "state log", "/tmp", "")

	logDir := state.SessionStateDir(store.Root(), "party-state-log")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		t.Fatalf("mkdir state dir: %v", err)
	}
	logBody := `{"agent":"claude","action":"tool_start"}
{"agent":"claude","action":"done"}
`
	if err := os.WriteFile(filepath.Join(logDir, "state.jsonl"), []byte(logBody), 0o644); err != nil {
		t.Fatalf("write state.jsonl: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "state", "log", "state-log")
	if out != logBody {
		t.Fatalf("state log output = %q, want %q", out, logBody)
	}
}

func TestStateLogMissingFileErrorsNicely(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-no-log", "no log", "/tmp", "")

	_, err := runCmdErr(t, store, sessionsRunner(), "state", "log", "no-log")
	if err == nil {
		t.Fatal("expected missing log error")
	}
	if !strings.Contains(err.Error(), "state log for party-no-log not found") {
		t.Fatalf("unexpected error: %v", err)
	}
}
