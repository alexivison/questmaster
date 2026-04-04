package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newBroadcastCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "broadcast [master-id] <message>",
		Short: "Broadcast a message to all workers of a master session",
		Long: `Broadcast a message to all workers of a master session.

If master-id is omitted, discovers the current tmux session and validates
it is a master session. This removes the need for shell-level discovery.`,
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()

			var masterID, msg string
			if len(args) == 2 {
				masterID, msg = args[0], args[1]
			} else {
				msg = args[0]
				id, err := discoverMasterSession(ctx, store, client)
				if err != nil {
					return err
				}
				masterID = id
			}

			svc := message.NewService(store, client)
			result, err := svc.Broadcast(ctx, masterID, msg)
			if err != nil {
				return err
			}
			w := cmd.OutOrStdout()
			if result.Registered == 0 {
				fmt.Fprintln(w, "No workers to broadcast to.")
			} else {
				fmt.Fprintf(w, "Broadcast sent to %d worker(s).\n", result.Delivered)
			}
			return nil
		},
	}
}
