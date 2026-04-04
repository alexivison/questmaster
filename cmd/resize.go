package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newResizeCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "resize <session-id>",
		Short: "Reset pane widths to canonical layout (sidebar 20%, shell 35%)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := session.NewService(store, client, repoRoot)
			if err := svc.Resize(cmd.Context(), args[0]); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Panes resized for session '%s'.\n", args[0])
			return nil
		},
	}
}
