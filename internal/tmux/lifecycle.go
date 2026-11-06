package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/alexivison/questmaster/internal/config"
)

// HasSession returns true if the named tmux session exists.
// Returns (false, nil) for genuine "session not found" and (false, error) for
// transport failures (connection refused, no server running, etc.).
func (c *Client) HasSession(ctx context.Context, sessionID string) (bool, error) {
	_, err := c.runner.Run(ctx, "has-session", "-t", SessionTarget(sessionID))
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) && !exitErr.IsConnectionError() {
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
// Propagates transport errors (permission denied, lost server) so callers don't
// delete manifests for sessions that are still alive but temporarily inaccessible.
func (c *Client) KillSession(ctx context.Context, sessionID string) error {
	_, err := c.runner.Run(ctx, "kill-session", "-t", SessionTarget(sessionID))
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) && !exitErr.IsConnectionError() {
			return nil
		}
		return fmt.Errorf("kill-session %s: %w", sessionID, err)
	}
	return nil
}

// NewSession creates a detached tmux session, sized like the caller's own
// client when the caller runs in a pane on this server, and returns the ID of
// its one pane. Callers target that ID: the window and pane indexes depend on
// the server's base-index and pane-base-index.
func (c *Client) NewSession(ctx context.Context, name, windowName, cwd string) (string, error) {
	args := []string{"new-session", "-d", "-P", "-F", "#{pane_id}", "-s", name}
	if windowName != "" {
		args = append(args, "-n", windowName)
	}
	if client, ok, err := c.callerClient(ctx); err == nil && ok && client.width > 0 && client.height > 0 {
		args = append(args, "-x", strconv.Itoa(client.width), "-y", strconv.Itoa(client.height))
	}
	args = append(args, "-c", cwd)
	out, err := c.runner.Run(ctx, args...)
	if err != nil {
		return "", fmt.Errorf("new-session %s: %w", name, err)
	}
	pane := strings.TrimSpace(out)
	if !paneIDPattern.MatchString(pane) {
		return "", fmt.Errorf("new-session %s: reported pane %q, not a pane ID", name, pane)
	}
	return pane, nil
}

// tmuxClient is one attached tmux client.
type tmuxClient struct {
	name          string
	width, height int
}

// callerSession returns the session of the pane this process runs in, when
// that pane is on the client's server. TMUX and TMUX_PANE describe the server
// the caller runs in, which need not be this one: pane %3 there is a different
// pane here. ok is false outside tmux and inside another server.
func (c *Client) callerSession(ctx context.Context) (string, bool, error) {
	pane := os.Getenv("TMUX_PANE")
	socket, _, _ := strings.Cut(os.Getenv("TMUX"), ",")
	if pane == "" || socket == "" {
		return "", false, nil
	}
	out, err := c.runner.Run(ctx, "display-message", "-t", pane, "-p", "#{socket_path}\t#{pane_id}\t#{session_name}")
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) && !exitErr.IsConnectionError() {
			return "", false, nil
		}
		return "", false, fmt.Errorf("find caller pane %s: %w", pane, err)
	}
	// display-message prints empty pane fields for a pane it cannot find.
	fields := strings.Split(out, "\t")
	if len(fields) != 3 || canonicalTmuxSocket(fields[0]) != canonicalTmuxSocket(socket) || fields[1] != pane || fields[2] == "" {
		return "", false, nil
	}
	return fields[2], true, nil
}

func canonicalTmuxSocket(path string) string {
	if path == "/private/tmp" {
		return "/tmp"
	}
	if strings.HasPrefix(path, "/private/tmp/") {
		return "/tmp/" + strings.TrimPrefix(path, "/private/tmp/")
	}
	return path
}

// callerClient returns the client tmux treats as the caller's: the most
// recently active client showing the caller's session. Commands run with
// TMUX_PANE stripped, so tmux cannot find it on its own.
func (c *Client) callerClient(ctx context.Context) (tmuxClient, bool, error) {
	session, ok, err := c.callerSession(ctx)
	if err != nil || !ok {
		return tmuxClient{}, false, err
	}
	out, err := c.runner.Run(ctx, "list-clients", "-t", SessionTarget(session),
		"-F", "#{client_activity}\t#{client_name}\t#{client_width}\t#{client_height}")
	if err != nil {
		return tmuxClient{}, false, fmt.Errorf("list clients of %s: %w", session, err)
	}
	var best tmuxClient
	bestActivity := int64(-1)
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) != 4 || fields[1] == "" {
			continue
		}
		activity, err := strconv.ParseInt(fields[0], 10, 64)
		if err != nil || activity <= bestActivity {
			continue
		}
		width, _ := strconv.Atoi(fields[2])
		height, _ := strconv.Atoi(fields[3])
		best, bestActivity = tmuxClient{name: fields[1], width: width, height: height}, activity
	}
	return best, bestActivity >= 0, nil
}

// RespawnPane kills the current process in a pane and starts a new one in cwd.
//
// The command changes into cwd itself instead of relying on -c alone: a tmux
// server whose own working directory has been deleted (a removed worktree, for
// example) starts every new pane in that deleted directory and ignores -c.
func (c *Client) RespawnPane(ctx context.Context, target, cwd, cmd string) error {
	if cwd != "" {
		cmd = "cd -- " + config.ShellQuote(cwd) + " || exit 1; " + cmd
	}
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
	_, err := c.runner.Run(ctx, "new-window", "-t", SessionTarget(session), "-n", name, "-c", cwd)
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

// SetManagedPaneTitle keeps the Questmaster title in the pane border even when
// the program later changes tmux's native pane_title with an OSC sequence.
// Preserve the effective border format so existing tmux styling and the
// native title of other panes in this window continue to work.
func (c *Client) SetManagedPaneTitle(ctx context.Context, target, title string) error {
	const option = "@questmaster_title"
	const visibleTitle = "#{?#{==:#{@questmaster_title},},#{pane_title},#{@questmaster_title}}"

	format, err := c.runner.Run(ctx, "display-message", "-t", target, "-p", "#{pane-border-format}")
	if err != nil {
		return fmt.Errorf("read pane border format for %s: %w", target, err)
	}
	if err := c.SetPaneOption(ctx, target, option, title); err != nil {
		return err
	}
	if !strings.Contains(format, "#{@questmaster_title}") {
		if strings.Contains(format, "#{pane_title}") {
			format = strings.ReplaceAll(format, "#{pane_title}", visibleTitle)
		} else if format == "" {
			format = "#{?#{==:#{@questmaster_title},},,#{@questmaster_title}}"
		} else {
			format += "#{?#{==:#{@questmaster_title},},, #{@questmaster_title}}"
		}
		if err := c.SetPaneOption(ctx, target, "pane-border-format", format); err != nil {
			// Older tmux versions only accept this option at window scope.
			if fallbackErr := c.SetWindowOption(ctx, target, "pane-border-format", format); fallbackErr != nil {
				return errors.Join(err, fallbackErr)
			}
		}
	}
	return c.SelectPaneTitle(ctx, target, title)
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

// SetSessionOption sets a session option.
func (c *Client) SetSessionOption(ctx context.Context, session, key, value string) error {
	_, err := c.runner.Run(ctx, "set-option", "-t", SessionTarget(session), key, value)
	if err != nil {
		return fmt.Errorf("set session option %s on %s: %w", key, session, err)
	}
	return nil
}

// SetEnvironment sets a session environment variable.
func (c *Client) SetEnvironment(ctx context.Context, session, key, value string) error {
	_, err := c.runner.Run(ctx, "set-environment", "-t", SessionTarget(session), key, value)
	if err != nil {
		return fmt.Errorf("set-environment %s in %s: %w", key, session, err)
	}
	return nil
}

// UnsetEnvironment removes a variable from one session's environment. There is
// no global form: the global environment belongs to every session on the server.
func (c *Client) UnsetEnvironment(ctx context.Context, session, key string) error {
	_, err := c.runner.Run(ctx, "set-environment", "-t", SessionTarget(session), "-u", key)
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
	out, err := c.runner.Run(ctx, "show-environment", "-t", SessionTarget(session), key)
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
	if _, v, ok := strings.Cut(out, "="); ok {
		return v, true, nil
	}
	return "", false, nil
}

// SetHook registers a tmux hook on a session.
func (c *Client) SetHook(ctx context.Context, session, hookName, cmd string) error {
	_, err := c.runner.Run(ctx, "set-hook", "-t", SessionTarget(session), hookName, cmd)
	if err != nil {
		return fmt.Errorf("set-hook %s on %s: %w", hookName, session, err)
	}
	return nil
}

// SwitchClient moves the caller's own client to a session. The caller must run
// in a pane on this server; the client is the one showing that pane's session,
// never a guess among other clients.
func (c *Client) SwitchClient(ctx context.Context, sessionID string) error {
	client, ok, err := c.callerClient(ctx)
	if err != nil {
		return fmt.Errorf("switch-client to %s: %w", sessionID, err)
	}
	if !ok {
		return fmt.Errorf("switch-client to %s: this terminal shows no session on Questmaster's tmux server", sessionID)
	}
	if _, err := c.runner.Run(ctx, "switch-client", "-c", client.name, "-t", SessionTarget(sessionID)); err != nil {
		return fmt.Errorf("switch-client to %s: %w", sessionID, err)
	}
	return nil
}

// SessionName returns the session of the pane this process runs in. It fails
// outside tmux and inside a pane on another server.
func (c *Client) SessionName(ctx context.Context) (string, error) {
	session, ok, err := c.callerSession(ctx)
	if err != nil {
		return "", fmt.Errorf("session name: %w", err)
	}
	if !ok {
		return "", errors.New("session name: not running in a pane on Questmaster's tmux server")
	}
	return session, nil
}
