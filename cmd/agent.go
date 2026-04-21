package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/spf13/cobra"
)

func newAgentCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "agent",
		Short: "Query configured agents and roles",
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
			case "roles":
				for _, binding := range registry.Bindings() {
					fmt.Fprintln(cmd.OutOrStdout(), binding.Role)
				}
				return nil
			case "names":
				for _, name := range registry.Names() {
					fmt.Fprintln(cmd.OutOrStdout(), name)
				}
				return nil
			case "primary-name":
				binding, err := registry.ForRole(agent.RolePrimary)
				if err != nil {
					return err
				}
				fmt.Fprintln(cmd.OutOrStdout(), binding.Agent.Name())
				return nil
			case "companion-name":
				if !registry.HasRole(agent.RoleCompanion) {
					return nil
				}
				binding, err := registry.ForRole(agent.RoleCompanion)
				if err != nil {
					return err
				}
				fmt.Fprintln(cmd.OutOrStdout(), binding.Agent.Name())
				return nil
			case "evidence-required":
				for _, name := range requiredEvidenceTypes(cfg) {
					fmt.Fprintln(cmd.OutOrStdout(), name)
				}
				return nil
			default:
				return fmt.Errorf("unknown query %q", args[0])
			}
		},
	}
}

// requiredEvidenceTypes returns the operator's explicit override for the PR
// gate evidence set. When unset, the gate derives requirements from the
// session-scoped execution-preset instead — there is no full-cascade fallback.
func requiredEvidenceTypes(cfg *agent.Config) []string {
	if cfg == nil || len(cfg.Evidence.Required) == 0 {
		return nil
	}
	out := make([]string, len(cfg.Evidence.Required))
	copy(out, cfg.Evidence.Required)
	return out
}
