package config

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolvePartyCLICmd_GoRunFallback(t *testing.T) {
	// Isolate PATH: include only the directory containing `go`, not `party-cli`.
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("go not on PATH")
	}
	t.Setenv("PATH", filepath.Dir(goBin))

	repoRoot := t.TempDir()
	mainDir := filepath.Join(repoRoot, "tools", "party-cli")
	if err := os.MkdirAll(mainDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(mainDir, "main.go"), []byte("package main"), 0o644); err != nil {
		t.Fatal(err)
	}

	cmd, err := ResolvePartyCLICmd(repoRoot)
	if err != nil {
		t.Fatalf("expected go-run fallback, got error: %v", err)
	}

	if !strings.Contains(cmd, "go run") {
		t.Fatalf("expected 'go run' in command, got: %s", cmd)
	}

	if !strings.Contains(cmd, "PARTY_REPO_ROOT=") {
		t.Fatalf("expected PARTY_REPO_ROOT in command, got: %s", cmd)
	}
}

func TestResolvePartyCLICmd_GoAvailableButNoSource(t *testing.T) {
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skip("go not on PATH")
	}
	t.Setenv("PATH", filepath.Dir(goBin))

	_, err = ResolvePartyCLICmd("/nonexistent-repo")
	if err == nil {
		t.Fatal("expected error when source is missing")
	}
	if !strings.Contains(err.Error(), "Go available") {
		t.Fatalf("expected Go-available error message, got: %v", err)
	}
}

func TestResolvePartyCLICmd_NoGoNoPath(t *testing.T) {
	t.Setenv("PATH", t.TempDir())

	_, err := ResolvePartyCLICmd("/nonexistent")
	if err == nil {
		t.Fatal("expected error when neither binary nor go is available")
	}
	if !strings.Contains(err.Error(), "Go toolchain unavailable") {
		t.Fatalf("expected toolchain-unavailable message, got: %v", err)
	}
}
