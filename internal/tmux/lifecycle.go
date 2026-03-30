package tmux

import (
	"context"
	"errors"
	"fmt"
	"strings"
)

// HasSession returns true if the named tmux session exists.
func (c *Client) HasSession(ctx context.Context, sessionID string) (bool, error) {
	_, err := c.runner.Run(ctx, "has-session", "-t", sessionID)
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return false, nil
		}
		return false, fmt.Errorf("has-session %s: %w", sessionID, err)
	}
	return true, nil
}

// EnsureSessionRunning checks that a tmux session exists and returns a
// descriptive error if it does not. The label (e.g. "worker", "master") is
// included in the error message for context.
func (c *Client) EnsureSessionRunning(ctx context.Context, sessionID, label string) error {
	alive, err := c.HasSession(ctx, sessionID)
	if err != nil {
		return fmt.Errorf("check %s session: %w", label, err)
	}
	if !alive {
		return fmt.Errorf("%s session %q is not running", label, sessionID)
	}
	return nil
}

// KillSession destroys a tmux session. Returns nil if the session does not exist.
func (c *Client) KillSession(ctx context.Context, sessionID string) error {
	_, err := c.runner.Run(ctx, "kill-session", "-t", sessionID)
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return nil
		}
		return fmt.Errorf("kill-session %s: %w", sessionID, err)
	}
	return nil
}

// NewSession creates a detached tmux session.
// Temporarily unsets TMUX env to avoid "sessions should be nested with care" errors
// when called from within an existing tmux session (mirrors party.sh:party_create_session).
func (c *Client) NewSession(ctx context.Context, name, windowName, cwd string) error {
	// The Runner interface doesn't support env manipulation, so we use the
	// EnvRunner wrapper to clear TMUX for this call.
	_, err := c.runWithoutTMUX(ctx,
		"new-session", "-d", "-s", name, "-n", windowName, "-c", cwd,
	)
	if err != nil {
		return fmt.Errorf("new-session %s: %w", name, err)
	}
	return nil
}

// runWithoutTMUX executes a tmux command with TMUX env var filtered from the
// child process environment. Uses ExecRunner's filtered-env path when available;
// falls back to the standard Runner for mock/test runners where TMUX is irrelevant.
func (c *Client) runWithoutTMUX(ctx context.Context, args ...string) (string, error) {
	if er, ok := c.runner.(ExecRunner); ok {
		return er.RunWithoutEnv(ctx, "TMUX", args...)
	}
	return c.runner.Run(ctx, args...)
}

// RespawnPane kills the current process in a pane and starts a new one.
func (c *Client) RespawnPane(ctx context.Context, target, cwd, cmd string) error {
	_, err := c.runner.Run(ctx, "respawn-pane", "-k", "-t", target, "-c", cwd, cmd)
	if err != nil {
		return fmt.Errorf("respawn-pane %s: %w", target, err)
	}
	return nil
}

// SplitWindow creates a new pane by splitting an existing one.
// If horizontal is true, splits horizontally (-h); otherwise vertically.
// An optional pct sets the new pane's size as a percentage (-p).
func (c *Client) SplitWindow(ctx context.Context, target, cwd, cmd string, horizontal bool, pct ...int) error {
	args := []string{"split-window"}
	if horizontal {
		args = append(args, "-h")
	}
	if len(pct) > 0 && pct[0] > 0 {
		args = append(args, "-p", fmt.Sprintf("%d", pct[0]))
	}
	args = append(args, "-t", target, "-c", cwd)
	if cmd != "" {
		args = append(args, cmd)
	}
	_, err := c.runner.Run(ctx, args...)
	if err != nil {
		return fmt.Errorf("split-window %s: %w", target, err)
	}
	return nil
}

// RunShell executes a shell command in the background via tmux run-shell.
func (c *Client) RunShell(ctx context.Context, target, cmd string) error {
	_, err := c.runner.Run(ctx, "run-shell", "-t", target, "-b", cmd)
	if err != nil {
		return fmt.Errorf("run-shell %s: %w", target, err)
	}
	return nil
}

// ResizePane sets a pane's width to the given percentage string (e.g. "20%").
func (c *Client) ResizePane(ctx context.Context, target, width string) error {
	_, err := c.runner.Run(ctx, "resize-pane", "-t", target, "-x", width)
	if err != nil {
		return fmt.Errorf("resize-pane %s: %w", target, err)
	}
	return nil
}

// KillWindow destroys a tmux window. Returns nil if the window does not exist.
func (c *Client) KillWindow(ctx context.Context, target string) error {
	_, err := c.runner.Run(ctx, "kill-window", "-t", target)
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return nil
		}
		return fmt.Errorf("kill-window %s: %w", target, err)
	}
	return nil
}

// NewWindow creates a new window in a session.
func (c *Client) NewWindow(ctx context.Context, session, name, cwd string) error {
	_, err := c.runner.Run(ctx, "new-window", "-t", session, "-n", name, "-c", cwd)
	if err != nil {
		return fmt.Errorf("new-window in %s: %w", session, err)
	}
	return nil
}

// RenameWindow renames a window.
func (c *Client) RenameWindow(ctx context.Context, target, name string) error {
	_, err := c.runner.Run(ctx, "rename-window", "-t", target, name)
	if err != nil {
		return fmt.Errorf("rename-window %s: %w", target, err)
	}
	return nil
}

// SelectPane makes a pane the active pane.
func (c *Client) SelectPane(ctx context.Context, target string) error {
	_, err := c.runner.Run(ctx, "select-pane", "-t", target)
	if err != nil {
		return fmt.Errorf("select-pane %s: %w", target, err)
	}
	return nil
}

// SelectPaneTitle sets a pane's title via select-pane -T.
func (c *Client) SelectPaneTitle(ctx context.Context, target, title string) error {
	_, err := c.runner.Run(ctx, "select-pane", "-t", target, "-T", title)
	if err != nil {
		return fmt.Errorf("select-pane title %s: %w", target, err)
	}
	return nil
}

// SelectWindow makes a window active.
func (c *Client) SelectWindow(ctx context.Context, target string) error {
	_, err := c.runner.Run(ctx, "select-window", "-t", target)
	if err != nil {
		return fmt.Errorf("select-window %s: %w", target, err)
	}
	return nil
}

// SetPaneOption sets a pane option (-p).
func (c *Client) SetPaneOption(ctx context.Context, target, key, value string) error {
	_, err := c.runner.Run(ctx, "set-option", "-p", "-t", target, key, value)
	if err != nil {
		return fmt.Errorf("set pane option %s on %s: %w", key, target, err)
	}
	return nil
}

// SetWindowOption sets a window option (-w).
func (c *Client) SetWindowOption(ctx context.Context, target, key, value string) error {
	_, err := c.runner.Run(ctx, "set-option", "-w", "-t", target, key, value)
	if err != nil {
		return fmt.Errorf("set window option %s on %s: %w", key, target, err)
	}
	return nil
}

// SetEnvironment sets a session environment variable.
func (c *Client) SetEnvironment(ctx context.Context, session, key, value string) error {
	_, err := c.runner.Run(ctx, "set-environment", "-t", session, key, value)
	if err != nil {
		return fmt.Errorf("set-environment %s in %s: %w", key, session, err)
	}
	return nil
}

// UnsetEnvironment removes a session or global environment variable.
// Pass session="" for global (-g) unset.
func (c *Client) UnsetEnvironment(ctx context.Context, session, key string) error {
	args := []string{"set-environment"}
	if session == "" {
		args = append(args, "-g")
	} else {
		args = append(args, "-t", session)
	}
	args = append(args, "-u", key)
	_, err := c.runner.Run(ctx, args...)
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return nil
		}
		return fmt.Errorf("unset-environment %s: %w", key, err)
	}
	return nil
}

// ShowEnvironment reads a session environment variable.
// Returns the value and true if set, or "" and false if not set.
func (c *Client) ShowEnvironment(ctx context.Context, session, key string) (string, bool, error) {
	out, err := c.runner.Run(ctx, "show-environment", "-t", session, key)
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return "", false, nil
		}
		return "", false, fmt.Errorf("show-environment %s in %s: %w", key, session, err)
	}
	// Output format: "KEY=VALUE" or "-KEY" (unset)
	if len(out) > 0 && out[0] == '-' {
		return "", false, nil
	}
	for i, ch := range out {
		if ch == '=' {
			return out[i+1:], true, nil
		}
	}
	return "", false, nil
}

// SetHook registers a tmux hook on a session.
func (c *Client) SetHook(ctx context.Context, session, hookName, cmd string) error {
	_, err := c.runner.Run(ctx, "set-hook", "-t", session, hookName, cmd)
	if err != nil {
		return fmt.Errorf("set-hook %s on %s: %w", hookName, session, err)
	}
	return nil
}

// SwitchClient switches the current tmux client to the target session.
func (c *Client) SwitchClient(ctx context.Context, target string) error {
	_, err := c.runner.Run(ctx, "switch-client", "-t", target)
	if err != nil {
		return fmt.Errorf("switch-client to %s: %w", target, err)
	}
	return nil
}

// SwitchClientWithFallback tries switch-client, then falls back to explicit
// client targeting via list-clients. Required for popup contexts where the
// TTY isn't associated with a tmux client.
// When multiple clients exist, the first from list-clients is used. This is
// correct for the typical single-terminal case; multi-client setups may need
// explicit client targeting via SwitchClient.
func (c *Client) SwitchClientWithFallback(ctx context.Context, target string) error {
	_, err := c.runner.Run(ctx, "switch-client", "-t", target)
	if err == nil {
		return nil
	}
	// Only fall back on ExitError (tmux ran but failed to find client).
	// Other errors (missing binary, context cancelled) propagate immediately.
	var exitErr *ExitError
	if !errors.As(err, &exitErr) {
		return fmt.Errorf("switch-client to %s: %w", target, err)
	}

	// Enumerate clients and target the first one explicitly.
	out, err := c.runner.Run(ctx, "list-clients", "-F", "#{client_name}")
	if err != nil {
		return fmt.Errorf("switch-client to %s: initial switch failed and cannot list clients: %w", target, err)
	}
	client := strings.SplitN(strings.TrimSpace(out), "\n", 2)[0]
	if client == "" {
		return fmt.Errorf("switch-client to %s: no tmux clients found", target)
	}

	_, err = c.runner.Run(ctx, "switch-client", "-c", client, "-t", target)
	if err != nil {
		return fmt.Errorf("switch-client to %s via client %s: %w", target, client, err)
	}
	return nil
}

// SessionName returns the current tmux session name.
func (c *Client) SessionName(ctx context.Context) (string, error) {
	out, err := c.runner.Run(ctx, "display-message", "-p", "#{session_name}")
	if err != nil {
		return "", fmt.Errorf("session name: %w", err)
	}
	return strings.TrimSpace(out), nil
}

// ListSessionClients returns client TTYs attached to a session.
func (c *Client) ListSessionClients(ctx context.Context, sessionID string) ([]string, error) {
	out, err := c.runner.Run(ctx, "list-clients", "-t", sessionID, "-F", "#{client_tty}")
	if err != nil {
		return nil, fmt.Errorf("list-clients for %s: %w", sessionID, err)
	}
	var clients []string
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if line != "" {
			clients = append(clients, line)
		}
	}
	return clients, nil
}

// SwitchClientTarget switches a specific client to a target session.
func (c *Client) SwitchClientTarget(ctx context.Context, clientTTY, target string) error {
	_, err := c.runner.Run(ctx, "switch-client", "-c", clientTTY, "-t", target)
	if err != nil {
		return fmt.Errorf("switch-client -c %s -t %s: %w", clientTTY, target, err)
	}
	return nil
}
