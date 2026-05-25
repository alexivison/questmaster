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
			return svc.Resize(cmd.Context(), args[0])
		},
	}
}
