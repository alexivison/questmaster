package cmd

import (
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

func newDeleteCmd(store *state.Store, client *tmux.Client, repoRoot string, routers ...*tmuxroute.Router) *cobra.Command {
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
	return &cobra.Command{
		Use:   "delete <session-id>",
		Short: "Delete a questmaster session completely",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			svc := session.NewService(store, client, repoRoot)
			if router != nil {
				svc.Router = router
			}
			dropped, err := svc.Delete(cmd.Context(), sessionID)
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID      string `json:"session_id"`
				Deleted        bool   `json:"deleted"`
				DroppedWatches int    `json:"dropped_watches"`
			}{SessionID: sessionID, Deleted: true, DroppedWatches: dropped})
		},
	}
}
