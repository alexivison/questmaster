package cmd

import (
	"github.com/alexivison/questmaster/internal/state"
	"github.com/spf13/cobra"
)

func newRepoCmd(store *state.Store) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "repo",
		Short: "Manage repository display metadata",
	}
	cmd.AddCommand(newRepoColorCmd(store))
	return cmd
}

func newRepoColorCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:   "color <repo-identity> <color>",
		Short: "Set or clear a repository display color",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			color, err := cleanDisplayColorArg(args[1])
			if err != nil {
				return err
			}
			if err := state.NewRepoColorStore(store.Root()).Set(args[0], color); err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				RepoIdentity string `json:"repo_identity"`
				Color        string `json:"color"`
				Recolored    bool   `json:"recolored"`
			}{RepoIdentity: args[0], Color: color, Recolored: true})
		},
	}
}
