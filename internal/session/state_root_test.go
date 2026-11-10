//go:build linux || darwin

package session

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMain(m *testing.M) {
	if os.Getenv("QM_TEST_CLEANUP_HELPER") == "1" {
		os.Exit(m.Run())
	}
	root, err := os.MkdirTemp("", "qm-session-state-*")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("QUESTMASTER_STATE_ROOT", root); err != nil {
		panic(err)
	}
	// Generated cleanup hooks must resolve a harmless shim before parallel
	// tests run, independently of an installed Questmaster on the host.
	if err := os.WriteFile(filepath.Join(root, "questmaster"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		panic(err)
	}
	if err := os.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH")); err != nil {
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(root)
	os.Exit(code)
}

func setTestStateRoot(t *testing.T, root string) {
	t.Helper()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
}
