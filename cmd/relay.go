package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newRelayCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var messageFile string
	cmd := &cobra.Command{
		Use:   "relay <worker-id> [message]",
		Short: "Send a message to a worker's primary pane",
		Args:  cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			msg, err := messageFromArgsAndFile(cmd, args[1:], messageFile)
			if err != nil {
				return err
			}
			svc := message.NewService(store, client)
			ctx := cmd.Context()
			senderID, err := discoverSession(ctx, client)
			if err == nil {
				err = svc.RelayFrom(ctx, senderID, args[0], msg)
			} else {
				err = svc.Relay(ctx, args[0], msg)
			}
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				WorkerID  string `json:"worker_id"`
				Delivered bool   `json:"delivered"`
			}{WorkerID: args[0], Delivered: true})
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	return cmd
}
