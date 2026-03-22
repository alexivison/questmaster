package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	// WindowCodex is the hidden Codex window index.
	WindowCodex = 0
	// WindowWorkspace is the workspace window index.
	WindowWorkspace = 1

	// DefaultSendTimeout is the default timeout for delivery-confirmed sends.
	DefaultSendTimeout = 2 * time.Second
)

// Pane represents a tmux pane with its role metadata.
type Pane struct {
	SessionName string
	WindowIndex int
	PaneIndex   int
	Role        string // @party_role value
}

// Target returns the tmux target string for this pane.
func (p Pane) Target() string {
	return fmt.Sprintf("%s:%d.%d", p.SessionName, p.WindowIndex, p.PaneIndex)
}

// SendResult represents the outcome of a delivery-confirmed send.
type SendResult struct {
	Delivered bool
	Target    string
	Err       error
}

// Runner executes tmux commands and returns stdout.
type Runner interface {
	Run(ctx context.Context, args ...string) (string, error)
}

// ExecRunner implements Runner using os/exec.
type ExecRunner struct{}

var _ Runner = ExecRunner{}

// ExitError indicates a tmux command ran but exited with a non-zero status.
// This distinguishes "tmux ran but failed" from "tmux binary not found".
type ExitError struct {
	Code int
}

func (e *ExitError) Error() string { return fmt.Sprintf("tmux exited with status %d", e.Code) }

// Run executes a tmux command and returns its trimmed stdout.
// Wraps non-zero exits as *ExitError so callers can distinguish from missing-binary errors.
func (ExecRunner) Run(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "tmux", args...)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", &ExitError{Code: exitErr.ExitCode()}
		}
		return "", err
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// RunWithoutEnv executes a tmux command with the named env var filtered from
// the child process environment. Goroutine-safe — does not mutate process env.
func (ExecRunner) RunWithoutEnv(ctx context.Context, excludeKey string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "tmux", args...)
	cmd.Env = filterEnv(os.Environ(), excludeKey)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", &ExitError{Code: exitErr.ExitCode()}
		}
		return "", err
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// filterEnv returns a copy of environ with entries matching the key removed.
func filterEnv(environ []string, key string) []string {
	prefix := key + "="
	filtered := make([]string, 0, len(environ))
	for _, e := range environ {
		if !strings.HasPrefix(e, prefix) {
			filtered = append(filtered, e)
		}
	}
	return filtered
}

// Client provides typed tmux operations.
type Client struct {
	runner      Runner
	SendTimeout time.Duration
}

// NewClient creates a Client with the given Runner.
func NewClient(r Runner) *Client {
	return &Client{runner: r, SendTimeout: DefaultSendTimeout}
}

// NewExecClient creates a Client that executes real tmux commands.
func NewExecClient() *Client {
	return NewClient(ExecRunner{})
}
