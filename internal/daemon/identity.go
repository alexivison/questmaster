//go:build linux || darwin

// Package daemon owns the on-demand, single-instance Questmaster backend process.
package daemon

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func hash(s string, n int) string { return fmt.Sprintf("%x", sha256.Sum256([]byte(s)))[:n] }

// Identity derives a stable daemon key from a real executable path.
func Identity(root, home, executable string) (string, error) {
	path, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", fmt.Errorf("resolve executable: %w", err)
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return "", err
	}
	canonical, canonicalErr := filepath.EvalSymlinks(filepath.Join(home, ".local", "bin", "questmaster"))
	if canonicalErr == nil && path == canonical {
		return "canonical", nil
	}
	bin := filepath.Join(root, "daemon", "bin")
	if resolved, err := filepath.EvalSymlinks(bin); err == nil {
		bin = resolved
	}
	rel, err := filepath.Rel(bin, path)
	if err == nil {
		parts := strings.Split(rel, string(filepath.Separator))
		if len(parts) == 3 && parts[0] != "" && parts[0] != "." && parts[0] != ".." && parts[1] == "exe" && parts[2] == "qm" {
			return parts[0], nil
		}
	}
	for _, part := range strings.Split(path, string(filepath.Separator)) {
		if strings.HasPrefix(part, "go-build") {
			return "", fmt.Errorf("refusing transient Go build executable %s", path)
		}
	}
	temp, _ := filepath.EvalSymlinks(os.TempDir())
	if path == temp || strings.HasPrefix(path, temp+string(filepath.Separator)) || strings.HasPrefix(path, "/tmp/") || strings.HasPrefix(path, "/private/tmp/") {
		return "", fmt.Errorf("refusing temporary executable %s", path)
	}
	return "bin-" + hash(path, 16), nil
}

// DevIdentity is stable across rebuilds of a worktree.
func DevIdentity(worktree string) (string, error) {
	path, err := filepath.EvalSymlinks(worktree)
	if err != nil {
		return "", err
	}
	return "dev-" + hash(path, 16), nil
}

// SocketPath derives the socket path and verifies the private fallback directory.
func SocketPath(root, id string) (string, error) {
	return socketPathAt(root, id, "/tmp")
}

func socketPathAt(root, id, tempBase string) (string, error) {
	if id == "" || strings.ContainsAny(id, "/\\.") {
		return "", fmt.Errorf("invalid daemon identity %q", id)
	}
	primary := filepath.Join(root, "daemon", id+".sock")
	if len(primary) < 104 {
		return primary, nil
	}
	dir := filepath.Join(tempBase, fmt.Sprintf("qm-%d", os.Getuid()))
	if err := os.Mkdir(dir, 0o700); err != nil && !os.IsExist(err) {
		return "", err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return "", err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || !info.IsDir() || info.Mode().Perm() != 0o700 || int(stat.Uid) != os.Getuid() {
		return "", fmt.Errorf("unsafe daemon socket directory %s", dir)
	}
	path := filepath.Join(dir, hash(root, 12)+"-"+id+".sock")
	if len(path) >= 104 {
		return "", fmt.Errorf("daemon socket path too long: %s", path)
	}
	return path, nil
}
