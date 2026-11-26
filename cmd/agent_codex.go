package cmd

import (
	"os"

	"github.com/alexivison/questmaster/internal/agentavailability"
	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newAgentCodexCmd(store *state.Store) *cobra.Command {
	var binary string
	var settings []string
	cmd := &cobra.Command{
		Use: "codex [flags] -- [TUI arguments]", Short: "Run a session-owned Codex app-server and its TUI", Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if err := agentavailability.RequireEnabled(store.Root(), "codex"); err != nil {
				return err
			}
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
