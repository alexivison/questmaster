//go:build linux || darwin

package session

import (
	"path/filepath"
	"testing"
)

func TestDefaultAgentPathKeepsQuestmasterPrefixFirst(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), "qm-shim")
	home := t.TempDir()
	t.Setenv("QUESTMASTER_PATH_PREFIX", prefix)
	t.Setenv("HOME", home)
	t.Setenv("PATH", "/usr/bin:"+prefix)

	got := defaultAgentPath()
	wantFirst := filepath.SplitList(got)[0]
	if wantFirst != prefix {
		t.Fatalf("defaultAgentPath first dir = %q, want QUESTMASTER_PATH_PREFIX %q in %q", wantFirst, prefix, got)
	}
}

func TestAgentPathWithBinaryDirKeepsQuestmasterPrefixFirst(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), "qm-shim")
	agentBin := filepath.Join(t.TempDir(), "agent-bin", "codex")
	t.Setenv("QUESTMASTER_PATH_PREFIX", prefix)

	got := agentPathWithBinaryDir("/usr/bin:"+prefix, agentBin)
	parts := filepath.SplitList(got)
	if len(parts) < 2 {
		t.Fatalf("agentPathWithBinaryDir returned too few parts: %q", got)
	}
	if parts[0] != prefix {
		t.Fatalf("agentPathWithBinaryDir first dir = %q, want prefix %q in %q", parts[0], prefix, got)
	}
	if parts[1] != filepath.Dir(agentBin) {
		t.Fatalf("agentPathWithBinaryDir second dir = %q, want binary dir %q in %q", parts[1], filepath.Dir(agentBin), got)
	}
}
