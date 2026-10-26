package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/spf13/cobra"
)

func newAgentCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "agent",
		Short: "Query configured agents",
	}
	cmd.AddCommand(newAgentQueryCmd())
	return cmd
}

func newAgentQueryCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "query <mode>",
		Short: "Query agent config for hooks and scripts",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := agent.LoadConfig(nil)
			if err != nil {
				return err
			}
			registry, err := agent.NewRegistry(cfg)
			if err != nil {
				return err
			}

			switch args[0] {
			case "names":
				for _, name := range registry.Names() {
					fmt.Fprintln(cmd.OutOrStdout(), name)
				}
				return nil
			default:
				return fmt.Errorf("unknown query %q", args[0])
			}
		},
	}
}
