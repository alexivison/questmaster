package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newDeleteCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "delete <session-id>",
		Short: "Delete a party session completely",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			svc := session.NewService(store, client, repoRoot)
			if err := svc.Delete(cmd.Context(), sessionID); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Deleted: %s\n", sessionID)
			return nil
		},
	}
}
