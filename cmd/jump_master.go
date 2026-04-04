package cmd

import (
	"fmt"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newJumpMasterCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "jump-master",
		Short: "Switch to the parent master session from a worker",
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()
			w := cmd.OutOrStdout()

			session, err := client.SessionName(ctx)
			if err != nil {
				return fmt.Errorf("get session name: %w", err)
			}

			if !strings.HasPrefix(session, "party-") {
				fmt.Fprintln(w, "Not in a party session")
				return nil
			}

			// Check if current session is already a master.
			m, err := store.Read(session)
			if err == nil && m.SessionType == "master" {
				fmt.Fprintln(w, "Already in master session")
				return nil
			}

			// Look up parent_session from manifest.
			var parent string
			if err == nil {
				parent = m.ExtraString("parent_session")
			}

			if parent == "" {
				fmt.Fprintln(w, "No parent master session found")
				return nil
			}

			// Verify master is still running.
			alive, err := client.HasSession(ctx, parent)
			if err != nil {
				return fmt.Errorf("check master session: %w", err)
			}
			if !alive {
				fmt.Fprintf(w, "Master session '%s' is not running\n", parent)
				return nil
			}

			return client.SwitchClientWithFallback(ctx, parent)
		},
	}
}
