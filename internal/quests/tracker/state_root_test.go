//go:build linux || darwin

package tracker

import "testing"

func setTestStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	return root
}
