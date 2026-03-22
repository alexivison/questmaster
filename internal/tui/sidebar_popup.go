package tui

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// PeekPopupArgs returns tmux display-popup arguments for a read-only Codex peek.
// Returns nil when Codex is unavailable (guard behavior).
func PeekPopupArgs(sessionID string, codexAvailable bool) []string {
	if !codexAvailable {
		return nil
	}

	target := tmux.CodexTarget(sessionID)
	cmd := fmt.Sprintf("tmux capture-pane -t %s -p -S -100 | less -R", target)

	return tmux.PopupArgs(target, 80, 70, cmd)
}
