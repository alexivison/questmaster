package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

// attachSession shows the named session: inside tmux it switches the caller's
// client, outside it attaches this terminal.
func attachSession(ctx context.Context, store *state.Store, router *tmuxroute.Router, sessionID string) error {
	command, handle, switchClient, err := attachPlan(ctx, store, router, sessionID)
	if err != nil {
		return err
	}
	if switchClient {
		return handle.Client().SwitchClient(ctx, sessionID)
	}
	command.Stdin, command.Stdout, command.Stderr = os.Stdin, os.Stdout, os.Stderr
	return command.Run()
}

func attachPlan(ctx context.Context, store *state.Store, router *tmuxroute.Router, sessionID string) (*exec.Cmd, tmuxroute.Handle, bool, error) {
	m, err := store.Read(sessionID)
	if err != nil {
		return nil, tmuxroute.Handle{}, false, err
	}
	handle, err := router.Route(m)
	if err != nil {
		return nil, tmuxroute.Handle{}, false, err
	}
	alive, err := handle.Client().HasSession(ctx, sessionID)
	if err != nil {
		return nil, tmuxroute.Handle{}, false, err
	}
	if !alive {
		return nil, tmuxroute.Handle{}, false, fmt.Errorf("session %s is stopped; run qm continue %s", sessionID, sessionID)
	}
	if os.Getenv("TMUX") != "" {
		same, err := handle.Client().CallerOnServer(ctx)
		if err != nil {
			return nil, tmuxroute.Handle{}, false, err
		}
		if same {
			return nil, handle, true, nil
		}
	}
	command, err := handle.Command(ctx, "attach-session", "-t", tmux.SessionTarget(sessionID))
	if err != nil {
		return nil, tmuxroute.Handle{}, false, err
	}
	return command, handle, false, nil
}

func newAttachCmd(store *state.Store, router *tmuxroute.Router, routerErr error) *cobra.Command {
	return &cobra.Command{Use: "attach <session-id>", Short: "Attach to a live questmaster session", Args: cobra.ExactArgs(1), RunE: func(cmd *cobra.Command, args []string) error {
		if routerErr != nil {
			return routerErr
		}
		return attachSession(cmd.Context(), store, router, args[0])
	}}
}
