package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newSpawnCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		cwd        string
		agentFlags sessionAgentFlags
		prompt     string
		promptFile string
		questID    string
	}

	cmd := &cobra.Command{
		Use:   "spawn [master-id] [title]",
		Short: "Spawn a worker session from a master",
		Long: `Spawn a worker session from a master.

If master-id is omitted, discovers the current tmux session and validates
it is a master session.`,
		Args: cobra.MaximumNArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx := cmd.Context()
			var masterID, title string
			switch len(args) {
			case 2:
				masterID, title = args[0], args[1]
			case 1:
				// Single arg is always treated as title. Master is auto-discovered.
				// Use the two-arg form to specify master-id explicitly.
				title = args[0]
			}
			if masterID == "" {
				id, err := discoverMasterSession(ctx, store, client)
				if err != nil {
					return err
				}
				masterID = id
			}
			userPrompt, err := promptFromFlags(cmd, opts.prompt, opts.promptFile)
			if err != nil {
				return err
			}

			var q *quest.Quest
			if opts.questID != "" {
				var err error
				q, err = resolveAttachableQuest(opts.questID)
				if err != nil {
					return err
				}
				if title == "" {
					title = q.Title
				}
			}
			prompt := userPrompt
			if q != nil {
				prompt = spawnedQuestPrompt(q.ID, userPrompt)
			}

			masterManifest, err := store.Read(masterID)
			if err != nil {
				return fmt.Errorf("read master manifest: %w", err)
			}

			registry, err := session.WorkerSpawnRegistry(masterManifest, opts.agentFlags.ConfigOverrides())
			if err != nil {
				return err
			}
			resumeIDs, err := opts.agentFlags.ResolveResumeIDs(registry)
			if err != nil {
				return err
			}
			svc := session.NewService(store, client, repoRoot, registry)
			result, err := svc.Spawn(cmd.Context(), masterID, session.SpawnOpts{
				Title:     title,
				Cwd:       opts.cwd,
				ResumeIDs: resumeIDs,
				Prompt:    prompt,
				Detached:  true, // shell wrappers handle attach
				Registry:  registry,
			})
			if err != nil {
				return err
			}
			if opts.questID != "" {
				if err := state.StampQuest(result.SessionID, opts.questID); err != nil {
					return fmt.Errorf("stamp quest on %s: %w", result.SessionID, err)
				}
			}

			w := cmd.OutOrStdout()
			return writeJSON(w, struct {
				SessionID  string `json:"session_id"`
				MasterID   string `json:"master_id"`
				RuntimeDir string `json:"runtime_dir"`
				Cwd        string `json:"cwd"`
				Title      string `json:"title,omitempty"`
				QuestID    string `json:"quest_id,omitempty"`
			}{
				SessionID:  result.SessionID,
				MasterID:   masterID,
				RuntimeDir: result.RuntimeDir,
				Cwd:        result.Cwd,
				Title:      title,
				QuestID:    opts.questID,
			})
		},
	}

	cmd.Flags().StringVar(&opts.cwd, "cwd", "", "working directory (default: master's cwd)")
	opts.agentFlags.AddFlags(cmd)
	addDeprecatedLayoutFlag(cmd)
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the worker's primary agent")
	cmd.Flags().StringVar(&opts.promptFile, "prompt-file", "", "read initial prompt from a file, or '-' for stdin")
	cmd.Flags().StringVar(&opts.questID, "quest", "", "active quest id to start the worker on")

	return cmd
}

func spawnedQuestPrompt(questID, userPrompt string) string {
	seed := fmt.Sprintf("You are working on quest %s. Read it with `questmaster quest view %s`, work to its gates, and do not mark it done; only the Questmaster sets status.", questID, questID)
	if userPrompt != "" {
		return seed + "\n\n" + userPrompt
	}
	return seed
}
