//go:build linux || darwin

package session

import (
	"os"
	"testing"
)

func TestMain(m *testing.M) {
	root, err := os.MkdirTemp("", "qm-session-state-*")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("QUESTMASTER_STATE_ROOT", root); err != nil {
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
