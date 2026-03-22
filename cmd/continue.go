package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newContinueCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "continue <session-id>",
		Short: "Resume a stopped party session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			svc := session.NewService(store, client, repoRoot)
			result, err := svc.Continue(cmd.Context(), sessionID)
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if result.Reattach {
				fmt.Fprintf(w, "Session '%s' is already running.\n", result.SessionID)
			} else if result.Master {
				fmt.Fprintf(w, "Master session '%s' resumed.\n", result.SessionID)
			} else {
				fmt.Fprintf(w, "Party session '%s' resumed.\n", result.SessionID)
			}
			return nil
		},
	}
}
