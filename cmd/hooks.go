package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/hooks"
	"github.com/spf13/cobra"
)

// newHooksCmd builds `party-cli hooks {install,status,uninstall}`. The
// subcommand groups the per-agent installer surface described in PLAN.md
// "Hook installer" (lines 198–220).
func newHooksCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "hooks",
		Short: "Manage per-agent state hooks (install, status, uninstall)",
		Long: `Manage the agent-native hooks that drive party-cli's state tracker.

The installer writes a small shell script per agent and merges tagged
entries into each agent's config (Claude: settings.local.json overlay,
Codex: hooks.json, Pi: extension marker). Re-running install is
idempotent.`,
	}

	root.AddCommand(newHooksInstallCmd())
	root.AddCommand(newHooksStatusCmd())
	root.AddCommand(newHooksUninstallCmd())
	return root
}

func newHooksInstallCmd() *cobra.Command {
	var check bool
	cmd := &cobra.Command{
		Use:   "install [agent...]",
		Short: "Install state hooks for the given agents (default: all)",
		RunE: func(cmd *cobra.Command, args []string) error {
			m := hooks.NewManager()
			if check {
				ok, reports, err := m.CheckCurrent(args)
				if err != nil {
					return err
				}
				printStatus(cmd, reports)
				if !ok {
					return fmt.Errorf("one or more agents are not Current")
				}
				return nil
			}
			return m.Install(args)
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "exit non-zero if any installed agent is not Current")
	return cmd
}

func newHooksStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status [agent...]",
		Short: "Show per-agent install status",
		RunE: func(cmd *cobra.Command, args []string) error {
			m := hooks.NewManager()
			reports, err := m.Status(args)
			if err != nil {
				return err
			}
			printStatus(cmd, reports)
			return nil
		},
	}
}

func newHooksUninstallCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "uninstall [agent...]",
		Short: "Remove tagged state hook entries (leaves user-managed hooks alone)",
		RunE: func(cmd *cobra.Command, args []string) error {
			m := hooks.NewManager()
			return m.Uninstall(args)
		},
	}
}

func printStatus(cmd *cobra.Command, reports []hooks.Report) {
	w := cmd.OutOrStdout()
	for _, r := range reports {
		if r.Detail != "" {
			fmt.Fprintf(w, "%-8s %s (%s)\n", r.Agent, r.Status, r.Detail)
			continue
		}
		fmt.Fprintf(w, "%-8s %s\n", r.Agent, r.Status)
	}
}
