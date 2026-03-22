package cmd

import (
	"fmt"

	"github.com/anthropics/ai-config/tools/party-cli/internal/tui"
	"github.com/spf13/cobra"
)

// Version is set at build time via ldflags.
var Version = "dev"

// Option configures a root command. Used for test injection.
type Option func(*rootOpts)

type rootOpts struct {
	tuiLauncher func() error
}

// WithTUILauncher overrides the default TUI entrypoint.
func WithTUILauncher(fn func() error) Option {
	return func(o *rootOpts) { o.tuiLauncher = fn }
}

// NewRootCmd creates the root cobra command.
func NewRootCmd(opts ...Option) *cobra.Command {
	o := rootOpts{tuiLauncher: tui.Launch}
	for _, apply := range opts {
		apply(&o)
	}

	root := &cobra.Command{
		Use:   "party-cli",
		Short: "Unified CLI and TUI for party sessions",
		Long: `party-cli is the shared implementation surface for party sessions.

When invoked with no subcommand, it launches the Bubble Tea TUI.
When invoked with a subcommand, it runs in CLI mode.`,
		SilenceUsage:  true,
		SilenceErrors: true,
		RunE: func(_ *cobra.Command, _ []string) error {
			return o.tuiLauncher()
		},
	}

	root.AddCommand(newVersionCmd())

	return root
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the party-cli version",
		RunE: func(cmd *cobra.Command, _ []string) error {
			fmt.Fprintf(cmd.OutOrStdout(), "party-cli %s\n", Version)
			return nil
		},
	}
}

// Execute runs the root command.
func Execute() error {
	return NewRootCmd().Execute()
}
