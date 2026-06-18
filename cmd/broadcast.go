package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newBroadcastCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var messageFile string
	cmd := &cobra.Command{
		Use:   "broadcast [master-id] [message]",
		Short: "Broadcast a message to all workers of a master session",
		Long: `Broadcast a message to all workers of a master session.

If master-id is omitted, discovers the current tmux session and validates
it is a master session. This removes the need for shell-level discovery.`,
		Args: cobra.RangeArgs(0, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()

			masterID, msg, err := optionalTargetAndMessage(cmd, args, messageFile)
			if err != nil {
				return err
			}
			if masterID == "" {
				id, err := discoverMasterSession(ctx, store, client)
				if err != nil {
					return err
				}
				masterID = id
			}

			svc := message.NewService(store, client)
			senderID, err := discoverSession(ctx, client)
			var result message.BroadcastResult
			if err == nil {
				result, err = svc.BroadcastFrom(ctx, senderID, masterID, msg)
			} else {
				result, err = svc.Broadcast(ctx, masterID, msg)
			}
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				MasterID   string `json:"master_id"`
				Registered int    `json:"registered"`
				Delivered  int    `json:"delivered"`
			}{MasterID: masterID, Registered: result.Registered, Delivered: result.Delivered})
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	return cmd
}
