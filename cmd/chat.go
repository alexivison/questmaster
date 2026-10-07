package cmd

import (
	"fmt"
	"sort"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/workerfeed"
	"github.com/spf13/cobra"
)

func newChatCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var workerID, beforeText string
	var limit int
	var textOutput, expand bool
	cmd := &cobra.Command{
		Use:   "chat [master-id]",
		Short: "Read a master's worker chat feed",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			masterID := ""
			if len(args) == 1 {
				masterID = args[0]
			} else {
				id, err := discoverMasterSession(cmd.Context(), store, client)
				if err != nil {
					return err
				}
				masterID = id
			}
			page, err := workerfeed.ReadHistory(store.Root(), masterID, workerID, beforeText, limit)
			if err != nil {
				return err
			}
			if textOutput || expand {
				out := cmd.OutOrStdout()
				if rendered := workerfeed.RenderText(page.Entries, expand); rendered != "" {
					if _, err := fmt.Fprintln(out, rendered); err != nil {
						return err
					}
				}
				workerIDs := make([]string, 0, len(page.Errors))
				for id := range page.Errors {
					workerIDs = append(workerIDs, id)
				}
				sort.Strings(workerIDs)
				for _, id := range workerIDs {
					if _, err := fmt.Fprintf(out, "Worker %s: [Error] %s\n", id, page.Errors[id]); err != nil {
						return err
					}
				}
				return nil
			}
			return writeJSON(cmd.OutOrStdout(), page)
		},
	}
	cmd.Flags().StringVar(&workerID, "worker", "", "show one worker's feed")
	cmd.Flags().IntVar(&limit, "limit", workerfeed.DefaultLimit, "maximum entries to return")
	cmd.Flags().StringVar(&beforeText, "before", "", "return entries before an RFC3339 timestamp or page cursor")
	cmd.Flags().BoolVar(&textOutput, "text", false, "render a human-readable feed")
	cmd.Flags().BoolVar(&expand, "expand", false, "render each tool call with its safe activity summary")
	return cmd
}
