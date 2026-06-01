package main

import (
	"fmt"
	"os"
	"runtime/debug"

	"github.com/alexivison/questmaster/internal/quests/paths"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func appVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok || info.Main.Version == "" || info.Main.Version == "(devel)" {
		return "dev"
	}
	return info.Main.Version
}

// env holds the resolved Quests runtime namespace shared by all subcommands.
// It is populated in the root's PersistentPreRunE so every command runs under
// the same isolated paths.
type env struct {
	paths paths.Paths
}

// NewRootCmd builds the Quests cobra root. The bare command launches the
// cockpit (a placeholder until T7). A persistent --home flag overrides
// QUESTS_HOME for this invocation.
func NewRootCmd() *cobra.Command {
	e := &env{}
	var homeFlag string

	root := &cobra.Command{
		Use:   "quests",
		Short: "Plan-layer cockpit that runs alongside questmaster",
		Long: `quests is an evolution of questmaster: a plan layer (quests) over the
session substrate, with fully isolated runtime state under ~/.quests
(override with QUESTS_HOME).

With no subcommand it launches the cockpit. With a subcommand it runs in
CLI mode.`,
		SilenceUsage:  true,
		SilenceErrors: true,
		PersistentPreRunE: func(_ *cobra.Command, _ []string) error {
			return bootstrap(e, homeFlag)
		},
		RunE: func(cmd *cobra.Command, _ []string) error {
			// Cockpit TODO (T7). For now confirm the resolved namespace so
			// the isolation is visible while the TUI is built out.
			fmt.Fprintf(cmd.OutOrStdout(),
				"cockpit TODO — quests home: %s (state: %s)\n",
				e.paths.Home, e.paths.StateRoot())
			return nil
		},
	}

	root.PersistentFlags().StringVar(&homeFlag, "home", "",
		"Quests home directory (overrides QUESTS_HOME; default ~/.quests)")

	root.AddCommand(newVersionCmd())

	return root
}

// bootstrap resolves the Quests namespace and injects it into the reused
// spine. Exporting QUESTMASTER_STATE_ROOT routes the package-level state
// helpers and the agent-hook propagation path (session/launch.go) to the
// Quests state root, so Quests shares no state with questmaster.
func bootstrap(e *env, homeFlag string) error {
	e.paths = paths.ResolveWith(homeFlag)
	if err := os.Setenv(state.StateRootEnv, e.paths.StateRoot()); err != nil {
		return fmt.Errorf("set quests state root: %w", err)
	}
	return nil
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the quests version",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintf(cmd.OutOrStdout(), "quests %s\n", appVersion())
			return nil
		},
	}
}
