package cmd

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

// newSessionCmd groups the quest-aware session lifecycle commands: new (start
// on a quest), attach (assign an active quest to an existing session), and
// detach (return the quest to the board).
func newSessionCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session",
		Short: "Create, attach, and detach quest-linked sessions",
	}
	cmd.AddCommand(
		newSessionNewCmd(store, client, repoRoot),
		newSessionAttachCmd(store, client),
		newSessionDetachCmd(store, client),
	)
	return cmd
}

func newSessionNewCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		cwd        string
		master     bool
		masterID   string
		questID    string
		agentFlags sessionAgentFlags
		prompt     string
		attach     bool
		title      string
	}

	cmd := &cobra.Command{
		Use:   "new [title]",
		Short: "Start a session, optionally on an active quest",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) > 0 {
				opts.title = args[0]
			}

			// Resolve and validate the quest (active-only) before creating
			// anything, and seed the opening prompt from it.
			seed := ""
			if opts.questID != "" {
				if opts.masterID != "" {
					return fmt.Errorf("workers inherit the quest from their master; do not pass --quest with --master-id")
				}
				q, err := resolveAttachableQuest(opts.questID)
				if err != nil {
					return err
				}
				seed = quest.WorkingClause(q)
				if opts.title == "" {
					opts.title = q.Title
				}
			}

			registry, err := loadSessionRegistryWithOverrides(opts.agentFlags.ConfigOverrides())
			if err != nil {
				return err
			}
			resumeIDs, err := opts.agentFlags.ResolveResumeIDs(registry)
			if err != nil {
				return err
			}

			prompt := opts.prompt
			if seed != "" {
				if prompt != "" {
					prompt = seed + "\n\n" + prompt
				} else {
					prompt = seed
				}
			}

			svc := session.NewService(store, client, repoRoot, registry)
			result, err := svc.Start(cmd.Context(), session.StartOpts{
				Title:     opts.title,
				Cwd:       opts.cwd,
				Master:    opts.master,
				MasterID:  opts.masterID,
				ResumeIDs: resumeIDs,
				Prompt:    prompt,
				Detached:  true,
			})
			if err != nil {
				return err
			}

			// Stamp the link on the master/standalone (workers inherit, never
			// stamped). The quest returns to the board on detach.
			if opts.questID != "" {
				if err := state.StampQuest(result.SessionID, opts.questID); err != nil {
					return fmt.Errorf("stamp quest on %s: %w", result.SessionID, err)
				}
			}

			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "Session '%s' started.\n", result.SessionID)
			if opts.questID != "" {
				fmt.Fprintf(w, "On quest %s.\n", opts.questID)
			}
			fmt.Fprintf(w, "Runtime dir: %s\n", result.RuntimeDir)

			if opts.attach {
				return attachSession(cmd.Context(), client, result.SessionID)
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.cwd, "cwd", "", "working directory (default: current)")
	cmd.Flags().BoolVar(&opts.master, "master", false, "start as a master session")
	cmd.Flags().StringVar(&opts.masterID, "master-id", "", "parent master session ID (for worker spawn)")
	cmd.Flags().StringVar(&opts.questID, "quest", "", "active quest id to start on")
	opts.agentFlags.AddFlags(cmd)
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the primary agent")
	cmd.Flags().BoolVar(&opts.attach, "attach", false, "attach to session after creation")
	addDeprecatedLayoutFlag(cmd)

	return cmd
}

func newSessionAttachCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var questID string
	cmd := &cobra.Command{
		Use:   "attach <session-id>",
		Short: "Attach an active quest to an existing session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			if !state.IsValidSessionID(sessionID) {
				return fmt.Errorf("invalid session id %q (expected qm-*)", sessionID)
			}
			if questID == "" {
				return fmt.Errorf("--quest is required")
			}
			q, err := resolveAttachableQuest(questID)
			if err != nil {
				return err
			}
			if err := state.StampQuest(sessionID, questID); err != nil {
				return fmt.Errorf("stamp quest on %s: %w", sessionID, err)
			}
			// Inject the working brief into the running session.
			if err := injectWorkingBrief(cmd.Context(), store, client, sessionID, q); err != nil {
				return fmt.Errorf("inject quest brief: %w", err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Attached %s to quest %s.\n", sessionID, questID)
			return nil
		},
	}
	cmd.Flags().StringVar(&questID, "quest", "", "active quest id to attach")
	return cmd
}

func newSessionDetachCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "detach <session-id>",
		Short: "Detach a session from its quest (returns it to the board)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := args[0]
			if !state.IsValidSessionID(sessionID) {
				return fmt.Errorf("invalid session id %q (expected qm-*)", sessionID)
			}
			if err := state.ClearQuest(sessionID); err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "Detached %s.\n", sessionID)
			return nil
		},
	}
}

// resolveAttachableQuest loads a quest and enforces the active-only rule: only
// active quests are attachable; wip and done are refused.
func resolveAttachableQuest(id string) (*quest.Quest, error) {
	q, err := quest.DefaultStore().Load(id)
	if err != nil {
		return nil, err
	}
	if q.Status != quest.StatusActive {
		return nil, fmt.Errorf("quest %q is %q; only active quests are attachable", id, q.Status)
	}
	return q, nil
}

// injectWorkingBrief sends the quest's working clause to a session's primary
// pane, the same delivery path relay uses.
func injectWorkingBrief(ctx context.Context, store *state.Store, client *tmux.Client, sessionID string, q *quest.Quest) error {
	return message.NewService(store, client).Relay(ctx, sessionID, quest.WorkingClause(q))
}
