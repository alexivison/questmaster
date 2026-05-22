package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newReadCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var lines int

	cmd := &cobra.Command{
		Use:   "read <worker-id>",
		Short: "Read output from a worker's primary pane",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			svc := message.NewService(store, client)
			output, err := svc.Read(cmd.Context(), args[0], lines)
			if err != nil {
				return err
			}
			fmt.Fprintln(cmd.OutOrStdout(), output)
			return nil
		},
	}

	cmd.Flags().IntVar(&lines, "lines", 50, "number of lines to read")
	return cmd
}
