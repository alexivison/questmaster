//go:build linux || darwin

package tui

import "testing"

func setTestStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("PARTY_STATE_ROOT", root)
	return root
}
