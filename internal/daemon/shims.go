//go:build linux || darwin

package daemon

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// StableExecutable is the path shims and QUESTMASTER_BIN point at. It is a symlink to the
// installed binary, replaced only by rename, so a session keeps working when the target moves.
func StableExecutable(root string) string {
	return filepath.Join(root, "bin", "current", "qm")
}

// ensureStableExecutable points the stable path at executable. Only the canonical daemon moves an
// existing link. Any other daemon fills the link in only when nothing resolves, so a development
// build never takes over the sessions of the installed app.
func ensureStableExecutable(root, executable string, canonical bool) error {
	if !canonical && stableResolves(root) {
		return nil
	}
	target, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return fmt.Errorf("resolve stable target: %w", err)
	}
	target, err = filepath.Abs(target)
	if err != nil {
		return err
	}
	return retargetStable(root, target)
}

// installedIdentity reports whether id names an installed build: the canonical install or a go install
// (bin-). A development build (dev-) keeps its own executable and never touches the stable path.
func installedIdentity(id string) bool {
	return id == "canonical" || strings.HasPrefix(id, "bin-")
}

// ensureStableForIdentity points the stable path at an installed build. Development builds are skipped.
func ensureStableForIdentity(root, id, executable string) error {
	if !installedIdentity(id) {
		return nil
	}
	return ensureStableExecutable(root, executable, id == "canonical")
}

func stableResolves(root string) bool {
	_, err := filepath.EvalSymlinks(StableExecutable(root))
	return err == nil
}

func retargetStable(root, target string) error {
	stable := StableExecutable(root)
	dir := filepath.Dir(stable)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(stable)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err == nil {
		if info.Mode()&os.ModeSymlink == 0 {
			return fmt.Errorf("refusing to replace %s: not a link", stable)
		}
		if current, err := os.Readlink(stable); err == nil && current == target {
			return nil
		}
	}
	tmp := fmt.Sprintf("%s.%d.tmp", stable, os.Getpid())
	_ = os.Remove(tmp)
	if err := os.Symlink(target, tmp); err != nil {
		return err
	}
	if err := os.Rename(tmp, stable); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("retarget %s: %w", stable, err)
	}
	return nil
}

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
	target := executable
	if installedIdentity(id) {
		target = StableExecutable(root)
	}
	script := []byte("#!/bin/sh\nexec '" + strings.ReplaceAll(target, "'", "'\\''") + "' \"$@\"\n")
	// Keep concurrent forks from inheriting a writable shim descriptor just before
	// the rename makes that inode executable by its public path.
	syscall.ForkLock.Lock()
	defer syscall.ForkLock.Unlock()
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
		if err := file.Close(); err != nil {
			os.Remove(file.Name())
			return err
		}
		if err := os.Chmod(file.Name(), 0o700); err != nil {
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
