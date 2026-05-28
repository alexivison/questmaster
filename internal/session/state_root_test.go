//go:build linux || darwin

package session

import "testing"

func setTestStateRoot(t *testing.T, root string) {
	t.Helper()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
}
