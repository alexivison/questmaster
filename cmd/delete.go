package cmd

import (
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newDeleteCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "delete <session-id>",
		Short: "Delete a questmaster session completely",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			svc := session.NewService(store, client, repoRoot)
			if err := svc.Delete(cmd.Context(), sessionID); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID string `json:"session_id"`
				Deleted   bool   `json:"deleted"`
			}{SessionID: sessionID, Deleted: true})
		},
	}
}
