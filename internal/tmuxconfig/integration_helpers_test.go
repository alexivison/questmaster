package tmuxconfig_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func prepareConfig(t *testing.T, root string) error {
	t.Helper()
	// The cleanup hook must never execute the Go test binary. Give each test
	// a harmless command on its private PATH before generating enforcement.
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "questmaster"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		return err
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return tmuxconfig.Prepare(root)
}
