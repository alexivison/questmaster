package cmd

import (
	"context"
	"os"

	"github.com/alexivison/questmaster/internal/tmux"
)

// attachSession shows the named session: inside tmux it switches the caller's
// client, outside it attaches this terminal.
func attachSession(ctx context.Context, client *tmux.Client, sessionID string) error {
	if os.Getenv("TMUX") != "" {
		return client.SwitchClient(ctx, sessionID)
	}
	cmd := tmux.DefaultServer().Command(ctx, "attach-session", "-t", tmux.SessionTarget(sessionID))
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
