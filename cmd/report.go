package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newReportCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "report [session-id] <message>",
		Short: "Report back to the master session (worker → master)",
		Long: `Report back to the master session from a worker.

If session-id is omitted, discovers the current tmux session.`,
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			var sessionID, msg string
			if len(args) == 2 {
				sessionID, msg = args[0], args[1]
			} else {
				msg = args[0]
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
			fmt.Fprintf(cmd.OutOrStdout(), "Reported to master from %s.\n", sessionID)
			return nil
		},
	}
}
