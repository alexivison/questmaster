package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newStartCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		title      string
		cwd        string
		layout     string
		master     bool
		masterID   string
		agentFlags sessionAgentFlags
		prompt     string
		attach     bool
	}

	cmd := &cobra.Command{
		Use:   "start [title]",
		Short: "Start a new party session",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 {
				opts.title = args[0]
			}

			overrides := opts.agentFlags.ConfigOverrides()
			if opts.master {
				if overrides == nil {
					overrides = &agent.ConfigOverrides{}
				}
				// Master sessions replace the companion with the tracker.
				overrides.NoCompanion = true
			}

			registry, err := loadSessionRegistryWithOverrides(overrides)
			if err != nil {
				return err
			}
			claudeResumeID, codexResumeID, err := opts.agentFlags.ResolveResumeIDs(registry)
			if err != nil {
				return err
			}
			svc := session.NewService(store, client, repoRoot, registry)
			result, err := svc.Start(cmd.Context(), session.StartOpts{
				Title:          opts.title,
				Cwd:            opts.cwd,
				Layout:         session.LayoutMode(opts.layout),
				Master:         opts.master,
				MasterID:       opts.masterID,
				ClaudeResumeID: claudeResumeID,
				CodexResumeID:  codexResumeID,
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
	opts.agentFlags.AddFlags(cmd)
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the primary agent")
	cmd.Flags().BoolVar(&opts.attach, "attach", false, "attach to session after creation")
	// Note: by default, attach behavior is handled by shell wrappers (party.sh).
	// Use --attach to have party-cli attach directly after creating the session.

	return cmd
}

func loadSessionRegistry() (*agent.Registry, error) {
	return loadSessionRegistryWithOverrides(nil)
}

func loadSessionRegistryWithOverrides(overrides *agent.ConfigOverrides) (*agent.Registry, error) {
	cfg, err := agent.LoadConfig(overrides)
	if err != nil {
		return nil, err
	}
	return agent.NewRegistry(cfg)
}
