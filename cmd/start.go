package cmd

import (
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newStartCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		title        string
		cwd          string
		master       bool
		masterID     string
		agentFlags   sessionAgentFlags
		displayColor string
		prompt       string
		promptFile   string
		attach       bool
		fromApp      bool
	}

	cmd := &cobra.Command{
		Use:   "start [title]",
		Short: "Start a new questmaster session",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 {
				opts.title = args[0]
			}
			if err := validateStartCwd(opts.cwd); err != nil {
				return err
			}
			userPrompt, err := promptFromFlags(cmd, opts.prompt, opts.promptFile)
			if err != nil {
				return err
			}

			registry, err := loadSessionRegistryWithOverrides(opts.agentFlags.ConfigOverrides())
			if err != nil {
				return err
			}
			resumeIDs, err := opts.agentFlags.ResolveResumeIDs(registry)
			if err != nil {
				return err
			}
			svc := session.NewService(store, client, repoRoot, registry)
			result, err := svc.Start(cmd.Context(), session.StartOpts{
				Title:        opts.title,
				Cwd:          opts.cwd,
				Master:       opts.master,
				MasterID:     opts.masterID,
				DisplayColor: opts.displayColor,
				ResumeIDs:    resumeIDs,
				Prompt:       userPrompt,
				Detached:     true, // shell wrappers handle attach
				FromApp:      opts.fromApp,
			})
			if err != nil {
				return err
			}

			w := cmd.OutOrStdout()
			if opts.attach {
				if opts.master {
					fmt.Fprintf(w, "Master session '%s' started.\n", result.SessionID)
				} else {
					fmt.Fprintf(w, "Session '%s' started.\n", result.SessionID)
				}
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
	cmd.Flags().BoolVar(&opts.master, "master", false, "start as a master session")
	cmd.Flags().StringVar(&opts.masterID, "master-id", "", "parent master session ID (for worker spawn)")
	opts.agentFlags.AddFlags(cmd)
	cmd.Flags().StringVar(&opts.displayColor, "color", "", "session display color")
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the primary agent")
	cmd.Flags().StringVar(&opts.promptFile, "prompt-file", "", "read initial prompt from a file, or '-' for stdin")
	cmd.Flags().BoolVar(&opts.attach, "attach", false, "attach to session after creation")
	cmd.Flags().BoolVar(&opts.fromApp, "from-app", false, "deprecated compatibility no-op")
	// Keep attach opt-in so scripts can create detached sessions by default.
	addDeprecatedLayoutFlag(cmd)

	return cmd
}

func validateStartCwd(cwd string) error {
	if cwd == "" {
		return nil
	}
	info, err := os.Stat(cwd)
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("working directory does not exist: %s", cwd)
		}
		return fmt.Errorf("stat working directory %s: %w", cwd, err)
	}
	if !info.IsDir() {
		return fmt.Errorf("working directory is not a directory: %s", cwd)
	}
	return nil
}

// addDeprecatedLayoutFlag keeps older scripts that pass --layout working.
func addDeprecatedLayoutFlag(cmd *cobra.Command) {
	var layout string
	cmd.Flags().StringVar(&layout, "layout", "", "deprecated (ignored)")
	_ = cmd.Flags().MarkHidden("layout")
	_ = cmd.Flags().MarkDeprecated("layout", "the flag is ignored")
}

func loadSessionRegistryWithOverrides(overrides *agent.ConfigOverrides) (*agent.Registry, error) {
	cfg, err := agent.LoadConfig(overrides)
	if err != nil {
		return nil, err
	}
	return agent.NewRegistry(cfg)
}
