package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/hooks"
	"github.com/spf13/cobra"
)

// newHooksCmd builds `questmaster hooks {install,status,uninstall}` for
// managing each agent's state-tracking hook integration.
func newHooksCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "hooks",
		Short: "Manage per-agent state hooks (install, status, uninstall)",
		Long: `Manage the agent-native hooks that drive questmaster's state tracker.

The installer uses each agent's native integration: Claude settings.json plus
script, Codex hooks.json plus script and trusted_hash config, Pi sidecar marker,
and OpenCode plugin/role-agent files. Re-running install is
idempotent.`,
	}

	root.AddCommand(newHooksInstallCmd())
	root.AddCommand(newHooksStatusCmd())
	root.AddCommand(newHooksUninstallCmd())
	return root
}

func newHooksInstallCmd() *cobra.Command {
	var check bool
	var dryRun bool
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
			log := cmd.ErrOrStderr()
			if dryRun {
				log = cmd.OutOrStdout()
			}
			return m.InstallWithOptions(args, hooks.InstallOptions{DryRun: dryRun, Log: log})
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "exit non-zero if any installed agent is not Current")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print hook install actions without changing files")
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
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "uninstall [agent...]",
		Short: "Remove tagged state hook entries (leaves user-managed hooks alone)",
		RunE: func(cmd *cobra.Command, args []string) error {
			m := hooks.NewManager()
			log := cmd.ErrOrStderr()
			if dryRun {
				log = cmd.OutOrStdout()
			}
			return m.UninstallWithOptions(args, hooks.InstallOptions{DryRun: dryRun, Log: log})
		},
	}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "print hook uninstall actions without changing files")
	return cmd
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
