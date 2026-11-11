//go:build linux || darwin

package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestIdentity(t *testing.T) {
	t.Parallel()
	base := t.TempDir()
	root := filepath.Join(base, "state")
	home := filepath.Join(base, "home")
	if err := os.MkdirAll(filepath.Join(home, ".local", "bin"), 0o700); err != nil {
		t.Fatal(err)
	}
	canonical := filepath.Join(base, "installed", "qm")
	if err := os.MkdirAll(filepath.Dir(canonical), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(canonical, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(canonical, filepath.Join(home, ".local", "bin", "questmaster")); err != nil {
		t.Fatal(err)
	}
	dev := filepath.Join(root, "daemon", "bin", "dev-abc", "exe", "qm")
	if err := os.MkdirAll(filepath.Dir(dev), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dev, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	other := "/usr/bin/true"
	goBuild := filepath.Join(base, "go-build123", "qm")
	temporary := filepath.Join(base, "unmanaged", "qm")
	for _, path := range []string{goBuild, temporary} {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("binary"), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for _, tc := range []struct {
		name, path, want string
		reject           bool
	}{
		{"canonical", canonical, "canonical", false},
		{"dev", dev, "dev-abc", false},
		{"override", other, "bin-", false},
		{"go-build", goBuild, "", true},
		{"temp", temporary, "", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Identity(root, home, tc.path)
			if (err != nil) != tc.reject {
				t.Fatalf("Identity error = %v", err)
			}
			if tc.reject && !strings.Contains(err.Error(), "refusing") {
				t.Fatalf("wrong rejection: %v", err)
			}
			if !tc.reject && !strings.HasPrefix(got, tc.want) {
				t.Fatalf("Identity = %q, want prefix %q", got, tc.want)
			}
		})
	}
}

func TestDaemonIdentitySeparatesTmuxLabels(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	executable := writeEchoBinary(t, filepath.Join(root, "daemon", "bin", "dev-example", "exe", "qm"), "ok")
	c := Config{Root: root, Home: home, Executable: executable}
	_, plain, plainSocket, err := c.resolve()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("QUESTMASTER_TMUX_LABEL", "questmaster")
	_, explicit, explicitSocket, err := c.resolve()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_one")
	_, first, firstSocket, err := c.resolve()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_two")
	_, second, secondSocket, err := c.resolve()
	if err != nil {
		t.Fatal(err)
	}
	if plain == explicit || plain == first || first == second || plainSocket == explicitSocket || plainSocket == firstSocket || firstSocket == secondSocket {
		t.Fatalf("identities/sockets overlap: %q %q %q %q / %q %q %q %q", plain, explicit, first, second, plainSocket, explicitSocket, firstSocket, secondSocket)
	}
}

func TestDaemonRejectsInvalidTmuxLabelBeforeStart(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "default")
	root := t.TempDir()
	c := Config{Root: root, Home: t.TempDir(), Executable: writeEchoBinary(t, filepath.Join(root, "daemon", "bin", "dev-example", "exe", "qm"), "ok")}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	if err := Run(ctx, c, false); err == nil || !strings.Contains(err.Error(), "QUESTMASTER_TMUX_LABEL") {
		t.Fatalf("daemon start error = %v", err)
	}
}

func TestIdentityStableLinkStaysCanonicalAcrossRetarget(t *testing.T) {
	t.Parallel()
	base := t.TempDir()
	root := filepath.Join(base, "state")
	home := filepath.Join(base, "home")
	stable := filepath.Join(root, "bin", "current", "qm")
	first := writeEchoBinary(t, filepath.Join(base, "first", "qm"), "first")
	second := writeEchoBinary(t, filepath.Join(base, "second", "qm"), "second")
	if err := ensureStableExecutable(root, first, true); err != nil {
		t.Fatal(err)
	}
	for _, target := range []string{first, second} {
		if err := ensureStableExecutable(root, target, true); err != nil {
			t.Fatal(err)
		}
		got, err := Identity(root, home, stable)
		if err != nil || got != "canonical" {
			t.Fatalf("Identity(stable) after retarget to %s = %q, %v; want canonical", target, got, err)
		}
	}
}

func TestSocketPathFallback(t *testing.T) {
	t.Parallel()
	root := filepath.Join(t.TempDir(), strings.Repeat("long", 30))
	path, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	if len(path) >= 104 || !strings.HasPrefix(path, "/tmp/qm-") {
		t.Fatalf("fallback = %q", path)
	}
	info, err := os.Lstat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("fallback mode = %o", info.Mode().Perm())
	}
}

func TestSocketPathRejectsUnsafeFallbackDirectory(t *testing.T) {
	t.Parallel()
	root := filepath.Join(t.TempDir(), strings.Repeat("r", 120))
	for _, kind := range []string{"permissive", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			base := t.TempDir()
			dir := filepath.Join(base, fmt.Sprintf("qm-%d", os.Getuid()))
			if kind == "permissive" {
				if err := os.Mkdir(dir, 0o755); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.Symlink(t.TempDir(), dir); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := socketPathAt(root, "canonical", base); err == nil {
				t.Fatal("unsafe fallback accepted")
			}
		})
	}
}

func TestDevIdentityUsesWorktreeRealpath(t *testing.T) {
	t.Parallel()
	worktree := t.TempDir()
	alias := filepath.Join(t.TempDir(), "checkout")
	if err := os.Symlink(worktree, alias); err != nil {
		t.Fatal(err)
	}
	fromWorktree, err := DevIdentity(worktree)
	if err != nil {
		t.Fatal(err)
	}
	fromAlias, err := DevIdentity(alias)
	if err != nil {
		t.Fatal(err)
	}
	if fromWorktree != fromAlias || !strings.HasPrefix(fromWorktree, "dev-") || len(fromWorktree) != 20 {
		t.Fatalf("dev ids: %q, %q", fromWorktree, fromAlias)
	}
}
