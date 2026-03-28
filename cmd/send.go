package cmd

import (
	"errors"
	"fmt"
	"os"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newSendCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var opts struct {
		role    string
		session string
		window  int
		caller  string
	}

	cmd := &cobra.Command{
		Use:   "send [--role <role>] [--session <id>] <message>",
		Short: "Send text to a tmux pane by role with delivery confirmation",
		Long: `Send text to a tmux pane identified by @party_role.

Discovers the current session if --session is omitted. Resolves the target
pane via role metadata, then delivers with idle-check retry (matching the
tmux_send contract from party-lib.sh).

Exit codes:
  0   delivered
  75  pane busy / delivery dropped (EX_TEMPFAIL)
  76  sent but delivery unconfirmed (capture-pane miss)`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			message := args[0]

			sessionID := opts.session
			if sessionID == "" {
				id, err := discoverSession(ctx, client)
				if err != nil {
					return err
				}
				sessionID = id
			}

			// Master sessions have no Codex pane
			if opts.role == "codex" {
				m, err := store.Read(sessionID)
				if err == nil && m.SessionType == "master" {
					return fmt.Errorf("master sessions have no Wizard pane; route through a worker session")
				}
			}

			// Resolve pane by role. For codex, use sidebar layout (window 0).
			// For other roles, use workspace window (window 1).
			preferredWindow := opts.window
			if preferredWindow < 0 {
				switch opts.role {
				case "codex":
					preferredWindow = tmux.WindowCodex
				default:
					preferredWindow = tmux.WindowWorkspace
				}
			}

			target, err := client.ResolveRole(ctx, sessionID, opts.role, preferredWindow)
			if err != nil {
				return fmt.Errorf("resolve %s pane in %q: %w", opts.role, sessionID, err)
			}

			result := client.Send(ctx, target, message)
			if result.Err != nil {
				if errors.Is(result.Err, tmux.ErrSendTimeout) {
					fmt.Fprintf(cmd.ErrOrStderr(), "send: timeout sending to %q (pane busy)\n", target)
					os.Exit(75)
				}
				return result.Err
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.role, "role", "claude", "pane role to target (codex, claude, shell)")
	cmd.Flags().StringVar(&opts.session, "session", "", "session ID (default: auto-discover)")
	cmd.Flags().IntVar(&opts.window, "window", -1, "preferred window index (-1 for auto)")
	cmd.Flags().StringVar(&opts.caller, "caller", "", "caller identifier for diagnostics")

	return cmd
}
