package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newReportCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var messageFile string
	cmd := &cobra.Command{
		Use:   "report [session-id] [message]",
		Short: "Report back to the master session (worker → master)",
		Long: `Report back to the master session from a worker.

If session-id is omitted, discovers the current tmux session.`,
		Args: cobra.RangeArgs(0, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			sessionID, msg, err := optionalTargetAndMessage(cmd, args, messageFile)
			if err != nil {
				return err
			}
			if sessionID == "" {
				id, err := discoverSession(ctx, client)
				if err != nil {
					return err
				}
				sessionID = id
			}

			svc := message.NewService(store, client)
			if err := svc.Report(ctx, sessionID, msg); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID string `json:"session_id"`
				Reported  bool   `json:"reported"`
			}{SessionID: sessionID, Reported: true})
		},
	}
	cmd.Flags().StringVar(&messageFile, "message-file", "", "read message from a file, or '-' for stdin")
	return cmd
}
