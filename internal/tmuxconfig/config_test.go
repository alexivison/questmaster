package tmuxconfig_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestEnsureUserFilesWritesOnce(t *testing.T) {
	root := t.TempDir()
	if err := tmuxconfig.EnsureUserFiles(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	for _, path := range []string{paths.Config, paths.StatusScript} {
		if err := os.WriteFile(path, []byte("user edit\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		before, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := tmuxconfig.EnsureUserFiles(root); err != nil {
			t.Fatal(err)
		}
		after, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if string(data) != "user edit\n" || !after.ModTime().Equal(before.ModTime()) {
			t.Fatalf("%s changed on second ensure", path)
		}
	}
}

func TestEnsureUserFilesRefusesSymlinkAndForeignType(t *testing.T) {
	for _, kind := range []string{"symlink", "directory"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			path := tmuxconfig.Paths(root).Config
			if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
				t.Fatal(err)
			}
			var err error
			if kind == "symlink" {
				err = os.Symlink(filepath.Join(root, "target"), path)
			} else {
				err = os.Mkdir(path, 0o700)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := tmuxconfig.EnsureUserFiles(root); err == nil {
				t.Fatal("accepted unsafe config path")
			}
		})
	}
}

func TestRenderQuotesPaths(t *testing.T) {
	root := filepath.Join(t.TempDir(), "it's a space")
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	data, err := os.ReadFile(paths.Config)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "{{CONFIG}}") || strings.Contains(string(data), "{{ENFORCED}}") || strings.Contains(string(data), "{{STATUS_SCRIPT}}") {
		t.Fatal("unrendered placeholder")
	}
	if !strings.Contains(string(data), "it'\\''s a space") {
		t.Fatal("apostrophe was not quoted in rendered paths")
	}
}

func TestWriteEnforcedAtomicOwnerOnly(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "questmaster")
	root := filepath.Join(t.TempDir(), "root", "..", "root")
	if err := tmuxconfig.WriteEnforced(root); err != nil {
		t.Fatal(err)
	}
	path := tmuxconfig.Paths(root).Enforced
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o", info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := tmuxconfig.RootMarker(root, "questmaster")
	if !strings.Contains(string(data), "@questmaster_root \""+hash+"\"") || !strings.Contains(string(data), "@questmaster_enforced 1") {
		t.Fatalf("enforced content: %s", data)
	}
	if !strings.Contains(string(data), "set-hook -g session-closed") {
		t.Fatal("global session-closed hook missing")
	}
	if err := os.WriteFile(path, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := tmuxconfig.WriteEnforced(root); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) == "old" {
		t.Fatal("enforced file was not rewritten")
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		t.Fatalf("left temporary files: %v", entries)
	}
}

func TestOwnershipMarkerRefusesForeignRootPerLabel(t *testing.T) {
	root := t.TempDir()
	other := t.TempDir()
	marker := tmuxconfig.RootMarker(root, "dev_1")
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	if err := tmuxconfig.WriteEnforced(root); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(tmuxconfig.Paths(root).Enforced)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "@questmaster_root \""+marker+"\"") {
		t.Fatalf("enforced marker = %q", data)
	}
	if !tmuxconfig.OwnsRoot(marker, root, "dev_1") {
		t.Fatal("own marker rejected")
	}
	if tmuxconfig.OwnsRoot(marker, other, "dev_1") || tmuxconfig.OwnsRoot(marker, root, "dev_2") {
		t.Fatal("foreign root or label accepted")
	}
	if !strings.HasPrefix(marker, "dev_1:") || len(marker) != len("dev_1:")+64 {
		t.Fatalf("marker = %q", marker)
	}
}

func TestCheckUsesPrivateSocketOnly(t *testing.T) {
	bin := t.TempDir()
	log := filepath.Join(bin, "calls")
	stub := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$QM_TMUX_LOG\"\n"
	if err := os.WriteFile(filepath.Join(bin, "tmux"), []byte(stub), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("QM_TMUX_LOG", log)
	file := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(file, []byte("set -g mouse on\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	errors, err := tmuxconfig.Check(context.Background(), file)
	if err != nil || len(errors) != 0 {
		t.Fatalf("Check: %q, %v", errors, err)
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if !strings.HasPrefix(line, "-S /tmp/") || strings.Contains(line, "-L") {
			t.Fatalf("unsafe tmux call: %q", line)
		}
	}
	if !strings.Contains(string(data), "-f /dev/null") || !strings.Contains(string(data), "source-file -n "+file) || !strings.Contains(string(data), "kill-server") {
		t.Fatalf("missing check commands: %s", data)
	}
}
