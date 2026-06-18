package cmd

import (
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

type workersJSONOutput struct {
	MasterID string               `json:"master_id"`
	Workers  []message.WorkerInfo `json:"workers"`
}

func newWorkersCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "workers [master-id]",
		Short: "List workers of a master session with status",
		Long: `List workers of a master session with their status.

If master-id is omitted, discovers the current tmux session and validates
it is a master session.`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			var masterID string
			if len(args) > 0 {
				masterID = args[0]
			} else {
				id, err := discoverMasterSession(ctx, store, client)
				if err != nil {
					return err
				}
				masterID = id
			}

			svc := message.NewService(store, client)
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
