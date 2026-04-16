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
	// WindowCompanion is the hidden companion window index.
	WindowCompanion = 0
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
// Stderr is captured so callers can distinguish "session not found" from
// transport errors (connection refused, no server running, etc.).
type ExitError struct {
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	if e.Stderr != "" {
		return fmt.Sprintf("tmux exited with status %d: %s", e.Code, e.Stderr)
	}
	return fmt.Sprintf("tmux exited with status %d", e.Code)
}

// IsConnectionError returns true if the error indicates an active tmux
// transport failure (permission denied, server crash) rather than the
// benign "no tmux server exists yet" case. The distinction matters because
// "no server" is functionally equivalent to "session not found", while a
// real transport failure (e.g. socket with wrong permissions) should not be
// silently treated as "session stopped".
func (e *ExitError) IsConnectionError() bool {
	s := e.Stderr
	if strings.Contains(s, "lost server") {
		return true
	}
	if strings.Contains(s, "error connecting") && !strings.Contains(s, "No such file or directory") {
		return true
	}
	return false
}

// Run executes a tmux command and returns its trimmed stdout.
// Wraps non-zero exits as *ExitError (with stderr) so callers can distinguish
// "session not found" from transport errors.
func (ExecRunner) Run(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "tmux", args...)
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", &ExitError{
				Code:   exitErr.ExitCode(),
				Stderr: strings.TrimRight(string(exitErr.Stderr), "\n"),
			}
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
			return "", &ExitError{
				Code:   exitErr.ExitCode(),
				Stderr: strings.TrimRight(string(exitErr.Stderr), "\n"),
			}
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

// RunBatch executes multiple tmux commands sequentially, stopping on the
// first error. Each element of cmds is a slice of args for one command.
// Returns the output of the last successful command (usually empty for
// set-option/select-pane).
func (c *Client) RunBatch(ctx context.Context, cmds ...[]string) (string, error) {
	var lastOut string
	for _, cmd := range cmds {
		out, err := c.runner.Run(ctx, cmd...)
		if err != nil {
			return "", err
		}
		lastOut = out
	}
	return lastOut, nil
}
