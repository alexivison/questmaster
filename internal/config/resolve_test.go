package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveQuestmasterCmd_UsesInstalledBinary(t *testing.T) {
	binDir := t.TempDir()
	binPath := filepath.Join(binDir, "questmaster")
	if err := os.WriteFile(binPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write questmaster stub: %v", err)
	}
	t.Setenv("PATH", binDir)

	cmd, err := ResolveQuestmasterCmd("/tmp/repo root")
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	if !strings.Contains(cmd, "PARTY_REPO_ROOT='/tmp/repo root'") {
		t.Fatalf("expected PARTY_REPO_ROOT in command, got: %s", cmd)
	}
	if !strings.Contains(cmd, ShellQuote(binPath)) {
		t.Fatalf("expected binary path in command, got: %s", cmd)
	}
	if strings.Contains(cmd, "go run") {
		t.Fatalf("standalone resolver must not use go run fallback: %s", cmd)
	}
}

func TestResolveQuestmasterCmd_NoPath(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	_, err := ResolveQuestmasterCmd("/nonexistent")
	if err == nil {
		t.Fatal("expected error when binary is unavailable")
	}
	if !strings.Contains(err.Error(), "questmaster: not found on PATH") {
		t.Fatalf("unexpected error: %v", err)
	}
}
