// Package tmuxconfig owns the files used to start Questmaster's dedicated tmux
// server. The user config and status script are created once; enforced settings
// are regenerated before each server start.
package tmuxconfig

import (
	"context"
	"crypto/sha256"
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/tmux"
)

//go:embed assets/questmaster.conf.tmpl
var template []byte

//go:embed assets/git-status.sh
var statusScript []byte

//go:embed assets/enforced-block.conf
var enforcedBlock string

// FilePaths names the three files under a state root.
type FilePaths struct {
	Config       string `json:"config"`
	Enforced     string `json:"enforced"`
	StatusScript string `json:"status_script"`
}

// Paths returns absolute paths for a state root without creating anything.
func Paths(root string) FilePaths {
	abs, err := filepath.Abs(root)
	if err != nil {
		abs = filepath.Clean(root)
	}
	dir := filepath.Join(abs, "tmux")
	return FilePaths{
		Config:       filepath.Join(dir, "questmaster.conf"),
		Enforced:     filepath.Join(dir, "enforced.conf"),
		StatusScript: filepath.Join(dir, "git-status.sh"),
	}
}

// Template renders the built-in user config for root without writing it.
func Template(root string) string {
	paths := Paths(root)
	replacer := strings.NewReplacer(
		"{{CONFIG}}", quotePath(paths.Config),
		"{{ENFORCED}}", quotePath(paths.Enforced),
		"{{STATUS_SCRIPT}}", quotePath(paths.StatusScript),
	)
	return replacer.Replace(string(template))
}

func quotePath(path string) string {
	return "'" + strings.ReplaceAll(path, "'", "'\\''") + "'"
}

// EnsureUserFiles creates the user-owned files only when absent. Existing files
// must be regular files owned by this process's uid; their content is untouched.
func EnsureUserFiles(root string) error {
	paths := Paths(root)
	if err := ensureDir(filepath.Dir(paths.Config)); err != nil {
		return err
	}
	if err := createOnce(paths.Config, []byte(Template(root)), 0o600); err != nil {
		return err
	}
	return createOnce(paths.StatusScript, statusScript, 0o700)
}

// WriteEnforced atomically replaces Questmaster's enforced settings.
func WriteEnforced(root string) error {
	label, err := tmux.EffectiveLabel()
	if err != nil {
		return err
	}
	paths := Paths(root)
	dir := filepath.Dir(paths.Enforced)
	if err := ensureDir(dir); err != nil {
		return err
	}
	if err := validateExisting(paths.Enforced); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	block := enforcedBlock
	hash := RootMarker(root, label)
	block = strings.Replace(block, "<sha256 of the absolute state root>", hash, 1)
	qm, err := config.ResolveQuestmasterCmd("")
	if err != nil {
		// A standalone/test build may have no questmaster shim on PATH.
		// The running executable can still handle the hook for that build.
		exe, exeErr := os.Executable()
		if exeErr != nil {
			return fmt.Errorf("resolve cleanup command: %w", err)
		}
		qm = config.ShellQuote(exe)
	}
	shellCommand := qm + " tmux session-closed --server " + config.ShellQuote(label) + " -- #{q:hook_session_name}"
	hook := `run-shell -b "` + tmuxQuoted(shellCommand) + `"`
	block += "set-hook -g session-closed \"" + tmuxQuoted(hook) + "\"\n"
	f, err := os.CreateTemp(dir, ".enforced-*")
	if err != nil {
		return fmt.Errorf("create enforced temp file: %w", err)
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.WriteString(block); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(f.Name(), paths.Enforced); err != nil {
		return fmt.Errorf("replace enforced config: %w", err)
	}
	return nil
}

func tmuxQuoted(s string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`, `$`, `\$`).Replace(s)
}

// RootMarker binds a state root to one dedicated tmux label. The value carries
// the label and the SHA-256 of the cleaned absolute root.
func RootMarker(root, label string) string {
	paths := Paths(root)
	absoluteRoot := filepath.Dir(filepath.Dir(paths.Config))
	return fmt.Sprintf("%s:%x", label, sha256.Sum256([]byte(absoluteRoot)))
}

// OwnsRoot reports whether a server's marker belongs to root and label.
func OwnsRoot(marker, root, label string) bool {
	return marker == RootMarker(root, label)
}

// Prepare creates user files if needed and regenerates enforced settings.
func Prepare(root string) error {
	if err := EnsureUserFiles(root); err != nil {
		return err
	}
	return WriteEnforced(root)
}

func ensureDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() || !ownedByCurrentUser(info) {
		return fmt.Errorf("unsafe tmux config directory: %s", dir)
	}
	return os.Chmod(dir, 0o700)
}

func createOnce(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if errors.Is(err, os.ErrExist) {
		return validateExisting(path)
	}
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(path)
		return err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		os.Remove(path)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return err
	}
	return nil
}

func validateExisting(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || !ownedByCurrentUser(info) {
		return fmt.Errorf("unsafe tmux config file: %s", path)
	}
	return nil
}

func ownedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == uint32(os.Getuid())
}

// Check validates a file on a throwaway private tmux socket. It first parses
// the file, then sources it to expose runtime errors. Reported config errors
// are returned as strings; setup failures are returned as errors.
func Check(ctx context.Context, file string) ([]string, error) {
	absoluteFile, err := filepath.Abs(file)
	if err != nil {
		return nil, err
	}
	dir, err := os.MkdirTemp("/tmp", "qmcheck-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(dir)
	server := tmux.SocketServerWithConfig(filepath.Join(dir, "socket"), "/dev/null")
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_, _ = server.Run(stopCtx, "kill-server")
	}()
	if _, err := server.Run(ctx, "new-session", "-d", "-s", "qm-config-check", "sleep 60"); err != nil {
		return nil, err
	}
	if output, err := runSource(ctx, server, "source-file", "-n", absoluteFile); err != nil {
		return configErrors(output, err), nil
	}
	if output, err := runSource(ctx, server, "source-file", absoluteFile); err != nil {
		return configErrors(output, err), nil
	}
	return []string{}, nil
}

func runSource(ctx context.Context, server tmux.Server, args ...string) (string, error) {
	out, err := server.Command(ctx, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func configErrors(output string, err error) []string {
	if output != "" {
		return strings.Split(output, "\n")
	}
	return []string{err.Error()}
}
