package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newStopCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	return &cobra.Command{
		Use:   "stop [session-id]",
		Short: "Stop a party session (or all if no argument given)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			target := ""
			if len(args) > 0 {
				target = args[0]
			}

			svc := session.NewService(store, client, repoRoot)
			stopped, err := svc.Stop(cmd.Context(), target)
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if len(stopped) == 0 {
				fmt.Fprintln(w, "No active party sessions.")
			} else {
				for _, id := range stopped {
					fmt.Fprintf(w, "Stopped: %s\n", id)
				}
			}
			return nil
		},
	}
}
