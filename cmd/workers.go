package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

type workersJSONOutput struct {
	MasterID string               `json:"master_id"`
	Workers  []message.WorkerInfo `json:"workers"`
}

func newWorkersCmd(store *state.Store, client *tmux.Client, routes ...*tmuxroute.Router) *cobra.Command {
	return &cobra.Command{
		Use:   "workers [master-id]",
		Short: "List workers of a master session with status",
		Long: `List workers of a master session with their status.

If master-id is omitted, discovers the current tmux session and validates
it is a master session.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			router, err := commandRouter(store, client, routes)
			if err != nil {
				return err
			}
			var masterID string
			if len(args) > 0 {
				masterID = args[0]
			} else {
				id, err := discoverMasterSessionRouted(ctx, store, router)
				if err != nil {
					return err
				}
				masterID = id
			}

			svc := message.NewServiceWithRouter(store, router)
			workers, err := svc.Workers(ctx, masterID)
			if err != nil {
				return err
			}

			return writeJSON(cmd.OutOrStdout(), workersJSONOutput{
				MasterID: masterID,
				Workers:  workers,
			})
		},
	}
}
