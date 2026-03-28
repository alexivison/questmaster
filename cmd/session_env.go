package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newSessionEnvCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "session-env",
		Short: "Print session discovery variables for shell eval",
		Long: `Discover the current party session and print shell-eval-able variables.

Replaces the discover_session() + party_state_file() + party_runtime_dir()
pattern from party-lib.sh. Usage in shell scripts:

  eval "$(party-cli session-env)"
  echo "$SESSION_NAME"   # party-xxxx
  echo "$STATE_DIR"      # /tmp/party-xxxx
  echo "$STATE_FILE"     # ~/.party-state/party-xxxx.json
  echo "$RUNTIME_DIR"    # /tmp/party-xxxx`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx := cmd.Context()

			sessionID, err := discoverSession(ctx, client)
			if err != nil {
				return err
			}

			runtimeDir := filepath.Join(os.TempDir(), sessionID)
			if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
				return fmt.Errorf("create runtime dir: %w", err)
			}

			// Write session-name marker (matches party-lib.sh discover_session)
			_ = os.WriteFile(filepath.Join(runtimeDir, "session-name"), []byte(sessionID+"\n"), 0o644)

			stateFile := filepath.Join(store.Root(), sessionID+".json")

			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "SESSION_NAME=%q\n", sessionID)
			fmt.Fprintf(w, "STATE_DIR=%q\n", runtimeDir)
			fmt.Fprintf(w, "STATE_FILE=%q\n", stateFile)
			fmt.Fprintf(w, "RUNTIME_DIR=%q\n", runtimeDir)
			return nil
		},
	}
}
