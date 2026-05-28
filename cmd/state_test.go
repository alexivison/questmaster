//go:build linux || darwin

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestStateLogReadsStateJSONL(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-state-log", "state log", "/tmp", "")

	logDir := state.SessionStateDir(store.Root(), "qm-state-log")
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

func TestResolveStateSessionIDShorthand(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-alpha", "alpha", "/tmp", "")
	createManifest(t, store, "qm-beta", "beta", "/tmp", "")

	cases := map[string]string{
		"alpha":    "qm-alpha",
		"qm-alpha": "qm-alpha",
		"beta":     "qm-beta",
		"qm-beta":  "qm-beta",
	}
	for raw, want := range cases {
		got, err := resolveStateSessionID(store, raw)
		if err != nil {
			t.Fatalf("resolveStateSessionID(%q): %v", raw, err)
		}
		if got != want {
			t.Fatalf("resolveStateSessionID(%q) = %q, want %q", raw, got, want)
		}
	}
}

func TestStateLogMissingFileErrorsNicely(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-no-log", "no log", "/tmp", "")

	_, err := runCmdErr(t, store, sessionsRunner(), "state", "log", "no-log")
	if err == nil {
		t.Fatal("expected missing log error")
	}
	if !strings.Contains(err.Error(), "state log for qm-no-log not found") {
		t.Fatalf("unexpected error: %v", err)
	}
}
