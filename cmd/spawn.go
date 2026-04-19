package cmd

import (
	"fmt"

	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newSpawnCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	var opts struct {
		cwd        string
		agentFlags sessionAgentFlags
		prompt     string
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
				Prompt:    opts.prompt,
				Detached:  true, // shell wrappers handle attach
				Registry:  registry,
			})
			if err != nil {
				return err
			}

			fmt.Fprintf(cmd.OutOrStdout(), "Worker '%s' spawned for master '%s'.\n", result.SessionID, masterID)
			return nil
		},
	}

	cmd.Flags().StringVar(&opts.cwd, "cwd", "", "working directory (default: master's cwd)")
	opts.agentFlags.AddFlags(cmd)
	addDeprecatedLayoutFlag(cmd)
	cmd.Flags().StringVar(&opts.prompt, "prompt", "", "initial prompt for the primary agent")

	return cmd
}
