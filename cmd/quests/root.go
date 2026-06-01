package main

import (
	"context"
	"fmt"
	"os"
	"runtime/debug"

	"github.com/alexivison/questmaster/internal/quests/paths"
	"github.com/alexivison/questmaster/internal/quests/review"
	"github.com/alexivison/questmaster/internal/session"
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

// env holds the resolved Quests runtime namespace shared by all subcommands,
// plus the side-effecting hooks (editor, browser, diff viewer) that tests
// override. It is populated in the root's PersistentPreRunE so every command
// runs under the same isolated paths.
type env struct {
	paths paths.Paths

	// editFile opens path in the user's editor and returns when it closes.
	editFile func(path string) error
	// openInBrowser opens path (a quest HTML file) in the browser.
	openInBrowser func(path string) error
	// newViewer builds a diff viewer for the given binary (flag override).
	newViewer func(bin string) review.DiffViewer
	// launchTUI runs the cockpit; overridden in tests.
	launchTUI func() error
	// spawnSession launches an interactive session via the reused spine;
	// agentName overrides the primary agent ("" = default). Overridden in tests.
	spawnSession func(ctx context.Context, opts session.StartOpts, agentName string) (session.StartResult, error)
}

// defaultEnv returns an env wired with production side effects.
func defaultEnv() *env {
	e := &env{
		editFile:      editFileWithEditor,
		openInBrowser: openInBrowser,
		newViewer:     func(bin string) review.DiffViewer { return review.NewViewer(bin) },
	}
	e.launchTUI = e.launchCockpit
	e.spawnSession = e.defaultSpawnSession
	return e
}

// NewRootCmd builds the Quests cobra root. The bare command launches the
// cockpit (a placeholder until T7). A persistent --home flag overrides
// QUESTS_HOME for this invocation.
func NewRootCmd() *cobra.Command {
	return newRootCmdWithEnv(defaultEnv())
}

// newRootCmdWithEnv builds the root around a provided env, so tests can inject
// the editor/browser/viewer hooks.
func newRootCmdWithEnv(e *env) *cobra.Command {
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
		RunE: func(_ *cobra.Command, _ []string) error {
			return e.launchTUI()
		},
	}

	root.PersistentFlags().StringVar(&homeFlag, "home", "",
		"Quests home directory (overrides QUESTS_HOME; default ~/.quests)")

	root.AddCommand(newVersionCmd())
	root.AddCommand(newQuestCmd(e))
	root.AddCommand(newSessionCmd(e))

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
