package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMain(m *testing.M) {
	root, err := os.MkdirTemp("", "qm-cmd-state-*")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("QUESTMASTER_STATE_ROOT", root); err != nil {
		panic(err)
	}
	// Lifecycle commands generate cleanup hooks even with an injected tmux
	// runner. Keep their executable lookup inside this test environment.
	if err := os.WriteFile(filepath.Join(root, "questmaster"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		panic(err)
	}
	if err := os.Setenv("PATH", root+string(os.PathListSeparator)+os.Getenv("PATH")); err != nil {
		panic(err)
	}
	code := m.Run()
	for _, build := range []*cachedDaemonBuild{&cachedDaemonCLI, &cachedDaemonHelper, &cachedDaemonReplacement} {
		if build.path != "" {
			_ = os.RemoveAll(filepath.Dir(build.path))
		}
	}
	_ = os.RemoveAll(root)
	os.Exit(code)
}

func setTestStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_SERVER", "dev_previous")
	return root
}
