package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
)

var (
	// ErrRoleNotFound is returned when no pane matches the requested role.
	ErrRoleNotFound = errors.New("role not found")
	// ErrRoleAmbiguous is returned when multiple panes match the requested role.
	ErrRoleAmbiguous = errors.New("ambiguous role: multiple panes match")
)

var roleFallbacks = map[string]string{
	"primary":   "claude",
	"companion": "codex",
}

// ListSessions returns the names of all live tmux sessions.
// Returns an empty slice when tmux exits non-zero (no server, no sessions),
// matching the shell convention of `tmux ls ... || true`.
// Propagates other errors (missing binary, context cancellation).
func (c *Client) ListSessions(ctx context.Context) ([]string, error) {
	out, err := c.runner.Run(ctx, "list-sessions", "-F", "#{session_name}")
	if err != nil {
		// tmux ran but exited non-zero (no server, no sessions) → empty result.
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return nil, nil //nolint:nilnil
		}
		// Missing binary, context cancellation, OS errors → propagate.
		return nil, fmt.Errorf("list sessions: %w", err)
	}
	if out == "" {
		return nil, nil //nolint:nilnil
	}
	return strings.Split(out, "\n"), nil
}

// SessionInfo holds basic metadata about a live tmux session.
type SessionInfo struct {
	Name string
	Cwd  string
}

// ListSessionDetails returns name and active-pane CWD for all live sessions.
func (c *Client) ListSessionDetails(ctx context.Context) ([]SessionInfo, error) {
	out, err := c.runner.Run(ctx, "list-sessions", "-F", "#{session_name}\t#{pane_current_path}")
	if err != nil {
		var exitErr *ExitError
		if errors.As(err, &exitErr) {
			return nil, nil //nolint:nilnil
		}
		return nil, fmt.Errorf("list session details: %w", err)
	}
	if out == "" {
		return nil, nil //nolint:nilnil
	}
	lines := strings.Split(out, "\n")
	infos := make([]SessionInfo, 0, len(lines))
	for _, line := range lines {
		name, cwd, _ := strings.Cut(line, "\t")
		if name == "" {
			continue
		}
		infos = append(infos, SessionInfo{Name: name, Cwd: cwd})
	}
	return infos, nil
}

// SessionCwd returns the active pane's current path for the named session.
func (c *Client) SessionCwd(ctx context.Context, sessionID string) (string, error) {
	out, err := c.runner.Run(ctx, "display-message", "-t", sessionID, "-p", "#{pane_current_path}")
	if err != nil {
		return "", fmt.Errorf("session cwd %s: %w", sessionID, err)
	}
	return out, nil
}

// PaneTitle returns the current title of the given pane target.
func (c *Client) PaneTitle(ctx context.Context, target string) (string, error) {
	out, err := c.runner.Run(ctx, "display-message", "-t", target, "-p", "#{pane_title}")
	if err != nil {
		return "", fmt.Errorf("pane title %s: %w", target, err)
	}
	return out, nil
}

// CurrentSessionName returns the name of the tmux session this process is attached to.
// Only meaningful when the TMUX env var is set (i.e., running inside tmux).
func (c *Client) CurrentSessionName(ctx context.Context) (string, error) {
	args := []string{"display-message"}
	if pane := os.Getenv("TMUX_PANE"); pane != "" {
		args = append(args, "-t", pane)
	}
	args = append(args, "-p", "#{session_name}")
	out, err := c.runner.Run(ctx, args...)
	if err != nil {
		return "", fmt.Errorf("current session name: %w", err)
	}
	return out, nil
}

// ListPanes returns all panes in a session across all windows with their role metadata.
func (c *Client) ListPanes(ctx context.Context, sessionID string) ([]Pane, error) {
	out, err := c.runner.Run(ctx,
		"list-panes", "-s", "-t", sessionID,
		"-F", "#{window_index} #{pane_index} #{@party_role}",
	)
	if err != nil {
		return nil, fmt.Errorf("list panes for %s: %w", sessionID, err)
	}
	if out == "" {
		return nil, nil //nolint:nilnil
	}
	return parsePanes(sessionID, out)
}

// ResolveRole finds the pane with the given @party_role using window-aware lookup.
// If preferredWindow >= 0, that window is searched first; duplicate roles across
// different windows are allowed (matching party-lib.sh semantics). Ambiguity is
// only reported when multiple panes share the role within the same searched scope.
// Pass preferredWindow < 0 to search all windows without preference.
func (c *Client) ResolveRole(ctx context.Context, sessionID, role string, preferredWindow int) (string, error) {
	panes, err := c.ListPanes(ctx, sessionID)
	if err != nil {
		return "", err
	}

	target, err := resolveRole(panes, role, preferredWindow, sessionID)
	if err == nil {
		return target, nil
	}
	if !errors.Is(err, ErrRoleNotFound) {
		return "", err
	}

	fallbackRole, ok := roleFallbacks[role]
	if !ok {
		return "", err
	}
	target, fallbackErr := resolveRole(panes, fallbackRole, preferredWindow, sessionID)
	if fallbackErr == nil {
		return target, nil
	}
	if !errors.Is(fallbackErr, ErrRoleNotFound) {
		return "", fallbackErr
	}
	return "", err
}

func resolveRole(panes []Pane, role string, preferredWindow int, sessionID string) (string, error) {
	// Search preferred window first when specified.
	if preferredWindow >= 0 {
		target, err := resolveInWindow(panes, role, preferredWindow, sessionID)
		if err == nil {
			return target, nil
		}
		if !errors.Is(err, ErrRoleNotFound) {
			return "", err
		}
		// Not found in preferred window — fall through to remaining windows.
	}

	// Search remaining windows in index order, stopping at first match or ambiguity.
	// Mirrors party-lib.sh: sequential search, first hit wins or ambiguity aborts.
	windowMatches := groupByWindow(panes, role, preferredWindow)
	if len(windowMatches) == 0 {
		return "", fmt.Errorf("%w: %q in session %s", ErrRoleNotFound, role, sessionID)
	}
	// First window in sorted order decides: unique match returns, ambiguity aborts.
	winIdx := sortedKeys(windowMatches)[0]
	matches := windowMatches[winIdx]
	if len(matches) == 1 {
		return matches[0].Target(), nil
	}
	return "", fmt.Errorf("%w: %q found %d times in window %d of session %s",
		ErrRoleAmbiguous, role, len(matches), winIdx, sessionID)
}

// resolveInWindow searches for a role within a single window.
func resolveInWindow(panes []Pane, role string, window int, sessionID string) (string, error) {
	var matches []Pane
	for _, p := range panes {
		if p.WindowIndex == window && p.Role == role {
			matches = append(matches, p)
		}
	}
	switch len(matches) {
	case 0:
		return "", fmt.Errorf("%w: %q in window %d of session %s", ErrRoleNotFound, role, window, sessionID)
	case 1:
		return matches[0].Target(), nil
	default:
		return "", fmt.Errorf("%w: %q found %d times in window %d of session %s",
			ErrRoleAmbiguous, role, len(matches), window, sessionID)
	}
}

// groupByWindow groups panes matching a role by window index, excluding skipWindow.
func groupByWindow(panes []Pane, role string, skipWindow int) map[int][]Pane {
	result := make(map[int][]Pane)
	for _, p := range panes {
		if p.Role == role && p.WindowIndex != skipWindow {
			result[p.WindowIndex] = append(result[p.WindowIndex], p)
		}
	}
	return result
}

// sortedKeys returns the keys of a map in ascending order.
func sortedKeys(m map[int][]Pane) []int {
	keys := make([]int, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	return keys
}

// parsePanes parses tmux list-panes output into Pane structs.
// Expected format per line: "window_index pane_index role"
func parsePanes(sessionID, output string) ([]Pane, error) {
	lines := strings.Split(output, "\n")
	panes := make([]Pane, 0, len(lines))

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// Format: "window_index pane_index [role]"
		// Role may be empty if @party_role is not set.
		parts := strings.SplitN(line, " ", 3)
		if len(parts) < 2 {
			continue
		}

		winIdx, err := strconv.Atoi(parts[0])
		if err != nil {
			return nil, fmt.Errorf("parse window index %q: %w", parts[0], err)
		}
		paneIdx, err := strconv.Atoi(parts[1])
		if err != nil {
			return nil, fmt.Errorf("parse pane index %q: %w", parts[1], err)
		}

		role := ""
		if len(parts) == 3 {
			role = parts[2]
		}

		panes = append(panes, Pane{
			SessionName: sessionID,
			WindowIndex: winIdx,
			PaneIndex:   paneIdx,
			Role:        role,
		})
	}
	return panes, nil
}
