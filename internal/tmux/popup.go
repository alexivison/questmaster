package tmux

import "fmt"

// PopupArgs returns tmux display-popup arguments for launching a popup.
// The popup auto-closes on exit (-E flag).
func PopupArgs(target string, widthPct, heightPct int, env []string, command ...string) []string {
	args := []string{
		"display-popup", "-E",
		"-t", target,
		"-w", fmt.Sprintf("%d%%", widthPct),
		"-h", fmt.Sprintf("%d%%", heightPct),
	}
	for _, value := range env {
		if value == "" {
			continue
		}
		args = append(args, "-e", value)
	}
	args = append(args, command...)
	return args
}

// WorkspaceTarget returns the tmux target for the workspace window in a session.
func WorkspaceTarget(sessionID string) string {
	return fmt.Sprintf("%s:%d", sessionID, WindowWorkspace)
}
