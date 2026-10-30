package cmd

import (
	"fmt"
	"path/filepath"

	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newArtifactCreateCmd(store *state.Store, client *tmux.Client, sessionFlag *string) *cobra.Command {
	var label, sourcePath string
	cmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create and register an artifact for the current session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID, err := resolveArtifactSession(cmd.Context(), client, *sessionFlag)
			if err != nil {
				return err
			}
			projectID := resolveArtifactProjectID(store, sessionID)
			opts := state.ArtifactCreateOptions{Name: args[0], Label: label, ProjectID: projectID}
			if sourcePath != "" {
				opts.SourcePath, err = resolveArtifactPath(sourcePath)
				if err != nil {
					return err
				}
				if r, ok := repo.Resolve(opts.SourcePath); ok {
					opts.ProjectID = r.Identity
				}
			} else {
				opts.Content = cmd.InOrStdin()
			}
			artifact, err := state.CreateArtifactAt(artifactStateRoot(store), sessionID, opts)
			if err != nil {
				return err
			}
			fmt.Fprintf(cmd.OutOrStdout(), "session\t%s\nid\t%s\npath\t%s\n", sessionID, artifact.ID, filepath.Clean(artifact.Path))
			return nil
		},
	}
	cmd.Flags().StringVar(&label, "label", "", "display label (defaults to file name)")
	cmd.Flags().StringVar(&sourcePath, "from", "", "copy an existing file instead of reading standard input")
	return cmd
}
