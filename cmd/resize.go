package cmd

import (
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newResizeCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "resize <session-id>",
		Short: "Reset pane widths to canonical layout (sidebar 16%, shell 45%)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := session.NewService(store, client, repoRoot)
			if err := svc.Resize(cmd.Context(), args[0]); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID string `json:"session_id"`
				Resized   bool   `json:"resized"`
			}{SessionID: args[0], Resized: true})
		},
	}
}
