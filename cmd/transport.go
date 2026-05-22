package cmd

import (
	"errors"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/transport"
	"github.com/spf13/cobra"
)

func newTransportCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "transport <message>",
		Short: "Send a message to the peer pane in the current session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			sessionID, err := discoverSession(ctx, client)
			if err != nil {
				return err
			}

			svc := transport.NewService(store, client)
			result, err := svc.Deliver(ctx, sessionID, args[0])
			for _, warning := range result.Warnings {
				fmt.Fprintf(cmd.ErrOrStderr(), "warning: %v\n", warning)
			}
			if err != nil {
				if errors.Is(err, transport.ErrCompanionNotAvailable) {
					fmt.Fprintln(cmd.ErrOrStderr(), transport.CompanionNotAvailableMessage)
					return alreadyPrinted(err)
				}
				return err
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Delivered to %s in %s.\n", result.TargetRole, result.SessionID)
			return nil
		},
	}
}
