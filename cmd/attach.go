package cmd

import (
	"context"
	"os"
	"os/exec"

	"github.com/alexivison/questmaster/internal/tmux"
)

// attachSession switches to the named tmux session.
func attachSession(ctx context.Context, client *tmux.Client, sessionID string) error {
	if os.Getenv("TMUX") != "" {
		return client.SwitchClientWithFallback(ctx, sessionID)
	}
	cmd := exec.Command("tmux", "attach-session", "-t", sessionID)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
