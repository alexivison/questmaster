package tmux

import "fmt"

// PopupArgs returns tmux display-popup arguments for launching a popup.
// The popup auto-closes on exit (-E flag).
func PopupArgs(target string, widthPct, heightPct int, cmd string) []string {
	return []string{
		"display-popup", "-E",
		"-t", target,
		"-w", fmt.Sprintf("%d%%", widthPct),
		"-h", fmt.Sprintf("%d%%", heightPct),
		cmd,
	}
}

// CodexTarget returns the tmux target for the Codex window in a session.
func CodexTarget(sessionID string) string {
	return fmt.Sprintf("%s:%d", sessionID, WindowCodex)
}

// WorkspaceTarget returns the tmux target for the workspace window in a session.
func WorkspaceTarget(sessionID string) string {
	return fmt.Sprintf("%s:%d", sessionID, WindowWorkspace)
}
