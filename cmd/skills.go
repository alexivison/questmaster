package cmd

import (
	"fmt"
	"io"

	"github.com/alexivison/questmaster/internal/skills"
	"github.com/spf13/cobra"
)

func newSkillsCmd() *cobra.Command {
	root := &cobra.Command{
		Use:   "skills",
		Short: "Manage bundled Questmaster agent skills",
	}
	root.AddCommand(newSkillsInstallCmd(), newSkillsStatusCmd(), newSkillsUninstallCmd())
	return root
}

func newSkillsInstallCmd() *cobra.Command {
	var check bool
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "install",
		Short: "Install Questmaster skills into shared user skill directories",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if check && dryRun {
				return fmt.Errorf("--check and --dry-run cannot be used together")
			}
			installer, err := skills.NewFromEnvironment()
			if err != nil {
				return err
			}
			if check {
				reports, err := installer.Status()
				if err != nil {
					return err
				}
				printSkillStatus(cmd.OutOrStdout(), reports)
				for _, report := range reports {
					if report.Status != skills.Current {
						return fmt.Errorf("one or more skill copies are not Current")
					}
				}
				return nil
			}
			reports, err := installer.Install(dryRun)
			if err != nil {
				return err
			}
			out := cmd.ErrOrStderr()
			if dryRun {
				out = cmd.OutOrStdout()
			}
			printSkillPlan(out, reports, "install", dryRun)
			return nil
		},
	}
	cmd.Flags().BoolVar(&check, "check", false, "exit non-zero if any skill copy is not Current")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show planned installs without changing files")
	return cmd
}

func newSkillsStatusCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "status",
		Short: "Show status for each installed skill copy",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			installer, err := skills.NewFromEnvironment()
			if err != nil {
				return err
			}
			reports, err := installer.Status()
			if err != nil {
				return err
			}
			printSkillStatus(cmd.OutOrStdout(), reports)
			return nil
		},
	}
}

func newSkillsUninstallCmd() *cobra.Command {
	var dryRun bool
	cmd := &cobra.Command{
		Use:   "uninstall",
		Short: "Remove unchanged Questmaster-owned skill files",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			installer, err := skills.NewFromEnvironment()
			if err != nil {
				return err
			}
			reports, err := installer.Uninstall(dryRun)
			if err != nil {
				return err
			}
			out := cmd.ErrOrStderr()
			if dryRun {
				out = cmd.OutOrStdout()
			}
			printSkillPlan(out, reports, "uninstall", dryRun)
			return nil
		},
	}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show planned removals without changing files")
	return cmd
}

func printSkillStatus(w io.Writer, reports []skills.Report) {
	for _, report := range reports {
		fmt.Fprintf(w, "%-18s %-28s %s\n", report.Destination, report.Skill, report.Status)
		printSkillPaths(w, report)
		if report.Detail != "" {
			fmt.Fprintf(w, "  detail: %s\n", report.Detail)
		}
	}
}

func printSkillPlan(w io.Writer, reports []skills.Report, operation string, dryRun bool) {
	for _, report := range reports {
		action := ""
		switch operation {
		case "install":
			switch report.Status {
			case skills.Current:
				action = "already current"
			case skills.Outdated:
				action = "updated"
			case skills.NotInstalled:
				action = "installed"
			}
		case "uninstall":
			switch report.Status {
			case skills.Current, skills.Outdated:
				action = "removed"
			case skills.NotInstalled:
				action = "not installed"
			}
		}
		if dryRun {
			switch action {
			case "installed":
				action = "would install"
			case "updated":
				action = "would update"
			case "removed":
				action = "would remove"
			}
		}
		if action == "" {
			action = string(report.Status)
		}
		fmt.Fprintf(w, "%-18s %-28s %s\n", report.Destination, report.Skill, action)
		printSkillPaths(w, report)
	}
}

func printSkillPaths(w io.Writer, report skills.Report) {
	fmt.Fprintf(w, "  path: %s\n", report.UserPath)
	if report.ResolvedPath != "" {
		fmt.Fprintf(w, "  resolved: %s\n", report.ResolvedPath)
	}
}
