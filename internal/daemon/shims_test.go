//go:build linux || darwin

package daemon

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// writeEchoBinary writes a shell executable that prints label:<first argument>.
func writeEchoBinary(t *testing.T, path, label string) string {
	t.Helper()
	script := "#!/bin/sh\nprintf '" + label + ":%s' \"$1\"\n"
	writeTestExecutable(t, path, []byte(script))
	return path
}

func writeTestExecutable(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	tmpName := func() string {
		syscall.ForkLock.RLock()
		defer syscall.ForkLock.RUnlock()
		tmp, err := os.CreateTemp(filepath.Dir(path), "qm-test-*")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Remove(tmp.Name()) })
		if _, err := tmp.Write(data); err != nil {
			tmp.Close()
			t.Fatal(err)
		}
		if err := tmp.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(tmp.Name(), 0o700); err != nil {
			t.Fatal(err)
		}
		return tmp.Name()
	}()
	if err := os.Rename(tmpName, path); err != nil {
		t.Fatal(err)
	}
}

func runShim(t *testing.T, shim string) string {
	t.Helper()
	output, err := exec.Command(shim, "hello").Output()
	if err != nil {
		t.Fatalf("%s: %v", shim, err)
	}
	return string(output)
}

func TestInstalledShimsFollowTheStableLinkWithoutRewrite(t *testing.T) {
	t.Parallel()
	// A quote in the state root must not break the shim's script.
	root := filepath.Join(t.TempDir(), "state ' one")
	first := writeEchoBinary(t, filepath.Join(root, "first", "qm"), "first")
	second := writeEchoBinary(t, filepath.Join(root, "second", "qm"), "second")
	if err := ensureStableForIdentity(root, "canonical", first); err != nil {
		t.Fatal(err)
	}
	shims := map[string]string{}
	for _, id := range []string{"canonical", "bin-0123456789abcdef"} {
		if err := writeShims(root, id, first); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"qm", "questmaster"} {
			shims[id+"/"+name] = filepath.Join(root, "daemon", "bin", id, name)
		}
	}
	for name, shim := range shims {
		if got := runShim(t, shim); got != "first:hello" {
			t.Fatalf("%s before retarget = %q", name, got)
		}
	}
	if err := ensureStableForIdentity(root, "canonical", second); err != nil {
		t.Fatal(err)
	}
	for name, shim := range shims {
		if got := runShim(t, shim); got != "second:hello" {
			t.Fatalf("%s after retarget = %q, want the retargeted executable without rewriting the shim", name, got)
		}
	}
}

func TestDevShimKeepsItsExecutableAndLeavesTheStableLinkAlone(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	stable := filepath.Join(root, "bin", "current", "qm")
	installed := writeEchoBinary(t, filepath.Join(root, "installed", "qm"), "installed")
	dev := writeEchoBinary(t, filepath.Join(root, "dev", "exe", "qm"), "dev")
	if err := ensureStableForIdentity(root, "canonical", installed); err != nil {
		t.Fatal(err)
	}
	if err := ensureStableForIdentity(root, "dev-abc", dev); err != nil {
		t.Fatal(err)
	}
	if err := writeShims(root, "dev-abc", dev); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"qm", "questmaster"} {
		shim := filepath.Join(root, "daemon", "bin", "dev-abc", name)
		if got := runShim(t, shim); got != "dev:hello" {
			t.Fatalf("%s = %q, want the development executable", shim, got)
		}
	}
	got, err := filepath.EvalSymlinks(stable)
	want, wantErr := filepath.EvalSymlinks(installed)
	if err != nil || wantErr != nil || got != want {
		t.Fatalf("stable link resolves to %q (%v), want untouched %q", got, err, want)
	}
}

func TestStableLinkMovesOnlyWhereTheOwnerSaysOrNothingResolves(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	stable := filepath.Join(root, "bin", "current", "qm")
	dev := writeEchoBinary(t, filepath.Join(root, "dev", "qm"), "dev")
	installed := writeEchoBinary(t, filepath.Join(root, "installed", "qm"), "installed")
	resolves := func(want string) {
		t.Helper()
		want, err := filepath.EvalSymlinks(want)
		if err != nil {
			t.Fatal(err)
		}
		got, err := filepath.EvalSymlinks(stable)
		if err != nil || got != want {
			t.Fatalf("stable resolves to %q (%v), want %q", got, err, want)
		}
	}

	if err := ensureStableExecutable(root, dev, false); err != nil {
		t.Fatal(err)
	}
	resolves(dev)

	if err := ensureStableExecutable(root, installed, false); err != nil {
		t.Fatal(err)
	}
	resolves(dev)

	if err := ensureStableExecutable(root, installed, true); err != nil {
		t.Fatal(err)
	}
	resolves(installed)

	if err := os.Remove(installed); err != nil {
		t.Fatal(err)
	}
	if err := ensureStableExecutable(root, dev, false); err != nil {
		t.Fatal(err)
	}
	resolves(dev)
}

func TestStableLinkRefusesToReplaceARealFile(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	stable := filepath.Join(root, "bin", "current", "qm")
	if err := os.MkdirAll(filepath.Dir(stable), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stable, []byte("real binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	exe := writeEchoBinary(t, filepath.Join(root, "exe", "qm"), "exe")
	if err := ensureStableExecutable(root, exe, true); err == nil || !strings.Contains(err.Error(), "refusing") {
		t.Fatalf("ensure over a real file: err=%v", err)
	}
	data, err := os.ReadFile(stable)
	if err != nil || string(data) != "real binary" {
		t.Fatalf("real file changed: %q %v", data, err)
	}
}

func TestPreChangeSessionShimStillRunsAndNoBinaryIsRemoved(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	oldBinary := writeEchoBinary(t, filepath.Join(root, "old", "qm"), "old")
	// The shim a session started before this change keeps in QUESTMASTER_BIN.
	shim := filepath.Join(root, "daemon", "bin", "dev-old", "qm")
	writeTestExecutable(t, shim, []byte("#!/bin/sh\nexec '"+oldBinary+"' \"$@\"\n"))
	if got := runShim(t, shim); got != "old:hello" {
		t.Fatalf("pre-change shim before restart = %q", got)
	}

	newBinary := writeEchoBinary(t, filepath.Join(root, "new", "qm"), "new")
	if err := ensureStableForIdentity(root, "dev-old", newBinary); err != nil {
		t.Fatal(err)
	}
	if err := writeShims(root, "dev-old", newBinary); err != nil {
		t.Fatal(err)
	}
	if got := runShim(t, shim); got != "new:hello" {
		t.Fatalf("pre-change shim after restart = %q", got)
	}
	if _, err := os.Lstat(filepath.Join(root, "bin", "current", "qm")); !os.IsNotExist(err) {
		t.Fatalf("development restart created the stable link: %v", err)
	}
	if _, err := os.Stat(oldBinary); err != nil {
		t.Fatalf("old binary was removed: %v", err)
	}
}
