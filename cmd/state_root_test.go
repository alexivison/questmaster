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
