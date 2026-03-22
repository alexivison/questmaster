package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newBroadcastCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "broadcast <master-id> <message>",
		Short: "Broadcast a message to all workers of a master session",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := message.NewService(store, client)
			result, err := svc.Broadcast(cmd.Context(), args[0], args[1])
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
