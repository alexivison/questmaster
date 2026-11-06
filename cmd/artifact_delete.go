package cmd

import (
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newArtifactDeleteCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:   "delete <id-or-path>",
		Short: "Permanently delete an artifact file and all session links",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			root := artifactStateRoot(store)
			idOrPath := args[0]
			var err error
			if !looksLikeArtifactID(idOrPath) {
				idOrPath, err = resolveArtifactPath(idOrPath)
				if err != nil {
					return err
				}
			}
			removed, err := state.DeleteArtifactAt(root, idOrPath)
			if err != nil {
				return err
			}
			if !removed {
				return fmt.Errorf("artifact %q not found", args[0])
			}
			fmt.Fprintf(cmd.OutOrStdout(), "deleted\t%s\n", args[0])
			return nil
		},
	}
}
