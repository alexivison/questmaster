package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newContinueCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var attach bool

	cmd := &cobra.Command{
		Use:   "continue <session-id>",
		Short: "Resume a stopped party session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			if _, err := store.Read(sessionID); err != nil {
				return err
			}
			svc := session.NewService(store, client, repoRoot)
			result, err := svc.Continue(cmd.Context(), sessionID)
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			switch {
			case result.Master && result.Reattach:
				fmt.Fprintf(w, "Master session '%s' is already running.\n", result.SessionID)
			case result.Master:
				fmt.Fprintf(w, "Master session '%s' resumed.\n", result.SessionID)
			case result.Reattach:
				fmt.Fprintf(w, "Session '%s' is already running.\n", result.SessionID)
			default:
				fmt.Fprintf(w, "Party session '%s' resumed.\n", result.SessionID)
			}
			for _, wid := range result.RevivedWorkers {
				fmt.Fprintf(w, "  ↳ revived worker '%s'\n", wid)
			}
			for _, wid := range result.FailedWorkers {
				fmt.Fprintf(w, "  ↳ failed to revive '%s'\n", wid)
			}

			if attach {
				return attachSession(cmd.Context(), client, result.SessionID)
			}
			return nil
		},
	}

	cmd.Flags().BoolVar(&attach, "attach", false, "attach to session after resuming")
	return cmd
}
