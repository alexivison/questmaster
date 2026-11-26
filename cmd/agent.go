package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/agentavailability"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newAgentCmd(store *state.Store) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "agent",
		Short: "Query enabled agents",
	}
	cmd.AddCommand(newAgentQueryCmd(store))
	cmd.AddCommand(newAgentCodexCmd(store))
	return cmd
}

func newAgentQueryCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:   "query <mode>",
		Short: "Query agent config for hooks and scripts",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			switch args[0] {
			case "names":
				names, err := agentavailability.EnabledNames(store.Root())
				if err != nil {
					return err
				}
				for _, name := range names {
					fmt.Fprintln(cmd.OutOrStdout(), name)
				}
				return nil
			default:
				return fmt.Errorf("unknown query %q", args[0])
			}
		},
	}
}
