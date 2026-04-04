package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newStartCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		title        string
		cwd          string
		layout       string
		master       bool
		masterID     string
		resumeClaude string
		resumeCodex  string
		prompt       string
		attach       bool
	}

	cmd := &cobra.Command{
		Use:   "start [title]",
		Short: "Start a new party session",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 {
				opts.title = args[0]
			}

			svc := session.NewService(store, client, repoRoot)
			result, err := svc.Start(cmd.Context(), session.StartOpts{
				Title:          opts.title,
				Cwd:            opts.cwd,
				Layout:         session.LayoutMode(opts.layout),
				Master:         opts.master,
				MasterID:       opts.masterID,
				ClaudeResumeID: opts.resumeClaude,
				CodexResumeID:  opts.resumeCodex,
				Prompt:         opts.prompt,
				Detached:       true, // shell wrappers handle attach
			})
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if opts.master {
				fmt.Fprintf(w, "Master session '%s' started.\n", result.SessionID)
			} else {
				fmt.Fprintf(w, "Party session '%s' started.\n", result.SessionID)
			}
			fmt.Fprintf(w, "Runtime dir: %s\n", result.RuntimeDir)

			if opts.attach {
				return attachSession(cmd.Context(), client, result.SessionID)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.cwd, "cwd", "", "working directory (default: current)")
	cmd.Flags().StringVar(&opts.layout, "layout", "", "layout mode: classic or sidebar (default: from PARTY_LAYOUT)")
	cmd.Flags().BoolVar(&opts.master, "master", false, "start as a master session")
	cmd.Flags().StringVar(&opts.masterID, "master-id", "", "parent master session ID (for worker spawn)")
	cmd.Flags().StringVar(&opts.resumeClaude, "resume-claude", "", "Claude session ID to resume")
	cmd.Flags().StringVar(&opts.resumeCodex, "resume-codex", "", "Codex thread ID to resume")
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for Claude")
	cmd.Flags().BoolVar(&opts.attach, "attach", false, "attach to session after creation")
	// Note: by default, attach behavior is handled by shell wrappers (party.sh).
	// Use --attach to have party-cli attach directly after creating the session.

	return cmd
}
