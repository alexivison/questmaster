package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newSessionCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session",
		Short: "Create sessions and manage session metadata",
	}
	cmd.AddCommand(
		newSessionNewCmd(store, client, repoRoot),
		newSessionColorCmd(store),
	)
	return cmd
}

func newSessionColorCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:   "color <session-id> <color>",
		Short: "Set or clear a session display color",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			color, err := cleanDisplayColorArg(args[1])
			if err != nil {
				return err
			}
			if err := store.SetDisplayColor(args[0], color); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				SessionID string `json:"session_id"`
				Color     string `json:"color"`
				Recolored bool   `json:"recolored"`
			}{SessionID: args[0], Color: color, Recolored: true})
		},
	}
}

func newSessionNewCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		cwd        string
		shell      bool
		master     bool
		masterID   string
		agentFlags sessionAgentFlags
		prompt     string
		promptFile string
		attach     bool
		title      string
	}

	cmd := &cobra.Command{
		Use:   "new [title]",
		Short: "Start a session",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 {
				opts.title = args[0]
			}
			if err := validateShellSessionFlags(cmd, opts.shell); err != nil {
				return err
			}
			userPrompt, err := promptFromFlags(cmd, opts.prompt, opts.promptFile)
			if err != nil {
				return err
			}

			var registry *agent.Registry
			var resumeIDs map[string]string
			if !opts.shell {
				var err error
				registry, err = loadSessionRegistryWithOverrides(opts.agentFlags.ConfigOverrides())
				if err != nil {
					return err
				}
				resumeIDs, err = opts.agentFlags.ResolveResumeIDs(registry)
				if err != nil {
					return err
				}
			}

			svc := session.NewService(store, client, repoRoot, registry)
			result, err := svc.Start(cmd.Context(), session.StartOpts{
				Title:     opts.title,
				Cwd:       opts.cwd,
				Shell:     opts.shell,
				Master:    opts.master,
				MasterID:  opts.masterID,
				ResumeIDs: resumeIDs,
				Prompt:    userPrompt,
				Detached:  true,
			})
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if opts.attach {
				fmt.Fprintf(w, "Session '%s' started.\n", result.SessionID)
				fmt.Fprintf(w, "Runtime dir: %s\n", result.RuntimeDir)
			} else {
				if err := writeJSON(w, struct {
					SessionID  string `json:"session_id"`
					RuntimeDir string `json:"runtime_dir"`
					Cwd        string `json:"cwd"`
					Title      string `json:"title,omitempty"`
					Master     bool   `json:"master"`
					MasterID   string `json:"master_id,omitempty"`
				}{
					SessionID:  result.SessionID,
					RuntimeDir: result.RuntimeDir,
					Cwd:        result.Cwd,
					Title:      opts.title,
					Master:     opts.master,
					MasterID:   opts.masterID,
				}); err != nil {
					return err
				}
			}

			if opts.attach {
				return attachSession(cmd.Context(), client, result.SessionID)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.cwd, "cwd", "", "working directory (default: current)")
	cmd.Flags().BoolVar(&opts.shell, "shell", false, "start a plain terminal session")
	cmd.Flags().BoolVar(&opts.master, "master", false, "start as a master session")
	cmd.Flags().StringVar(&opts.masterID, "master-id", "", "parent master session ID (for worker spawn)")
	opts.agentFlags.AddFlags(cmd)
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the primary agent")
	cmd.Flags().StringVar(&opts.promptFile, "prompt-file", "", "read initial prompt from a file, or '-' for stdin")
	cmd.Flags().BoolVar(&opts.attach, "attach", false, "attach to session after creation")
	addDeprecatedLayoutFlag(cmd)

	return cmd
}
