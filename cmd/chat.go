package cmd

import (
	"fmt"

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
				_, err := fmt.Fprintln(cmd.OutOrStdout(), workerfeed.RenderText(page.Entries, expand))
				return err
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
