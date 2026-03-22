package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newWorkersCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "workers <master-id>",
		Short: "List workers of a master session with status",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := message.NewService(store, client)
			workers, err := svc.Workers(cmd.Context(), args[0])
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if len(workers) == 0 {
				fmt.Fprintln(w, "No workers registered.")
				return nil
			}

			fmt.Fprintf(w, "%-25s %-8s %s\n", "SESSION", "STATUS", "TITLE")
			for _, wi := range workers {
				title := wi.Title
				if title == "" {
					title = "-"
				}
				fmt.Fprintf(w, "%-25s %-8s %s\n", wi.SessionID, wi.Status, title)
			}
			return nil
		},
	}
}
