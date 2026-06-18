package cmd

import (
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID   string `json:"session_id"`
				SessionType string `json:"session_type"`
				Promoted    bool   `json:"promoted"`
			}{SessionID: sessionID, SessionType: "master", Promoted: true})
		},
	}
}
