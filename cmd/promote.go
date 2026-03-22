package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newPromoteCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "promote <session-id>",
		Short: "Promote a session to master",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			svc := session.NewService(store, client, repoRoot)
			if err := svc.Promote(cmd.Context(), sessionID); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Session '%s' promoted to master.\n", sessionID)
			return nil
		},
	}
}
