package cmd

import (
	"os"

	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newAgentCodexCmd() *cobra.Command {
	var binary string
	var settings []string
	cmd := &cobra.Command{
		Use: "codex [flags] -- [TUI arguments]", Short: "Run a session-owned Codex app-server and its TUI", Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return codexnative.Run(cmd.Context(), codexnative.Options{
				Binary: binary, RuntimeDir: os.Getenv(state.RuntimeDirEnv), Config: settings, Args: args,
				In: cmd.InOrStdin(), Out: cmd.OutOrStdout(), Err: cmd.ErrOrStderr(),
			})
		},
	}
	cmd.Flags().StringVar(&binary, "binary", "", "resolved Codex executable")
	cmd.Flags().StringArrayVar(&settings, "config", nil, "session configuration override")
	return cmd
}
