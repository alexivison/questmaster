//go:build linux || darwin

package daemon

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func writeShims(root, id, executable string) error {
	dir := filepath.Join(root, "daemon", "bin", id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	executableInfo, err := os.Stat(executable)
	if err != nil {
		return err
	}
	for _, name := range []string{"qm", "questmaster"} {
		if existing, err := os.Stat(filepath.Join(dir, name)); err == nil && os.SameFile(existing, executableInfo) {
			return fmt.Errorf("refusing to replace daemon binary with %s shim", name)
		}
	}
	script := []byte("#!/bin/sh\nexec '" + strings.ReplaceAll(executable, "'", "'\\''") + "' \"$@\"\n")
	for _, name := range []string{"qm", "questmaster"} {
		file, err := os.CreateTemp(dir, name+"-")
		if err != nil {
			return err
		}
		if _, err := file.Write(script); err != nil {
			file.Close()
			os.Remove(file.Name())
			return err
		}
		if err := file.Chmod(0o700); err != nil {
			file.Close()
			os.Remove(file.Name())
			return err
		}
		if err := file.Close(); err != nil {
			os.Remove(file.Name())
			return err
		}
		if err := os.Rename(file.Name(), filepath.Join(dir, name)); err != nil {
			os.Remove(file.Name())
			return fmt.Errorf("write %s shim: %w", name, err)
		}
	}
	return nil
}
