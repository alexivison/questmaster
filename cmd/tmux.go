package cmd

import (
	"encoding/json"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/spf13/cobra"
)

func newTmuxCmd(store *state.Store) *cobra.Command {
	tmuxCmd := &cobra.Command{Use: "tmux", Short: "Inspect Questmaster tmux configuration"}
	configCmd := &cobra.Command{Use: "config", Short: "Inspect Questmaster tmux config files"}
	configCmd.AddCommand(&cobra.Command{
		Use: "path", Short: "Print config file paths", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			label, err := tmux.EffectiveLabel()
			if err != nil {
				return err
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(struct {
				tmuxconfig.FilePaths
				EffectiveLabel string `json:"effective_label"`
			}{tmuxconfig.Paths(store.Root()), label})
		},
	})
	configCmd.AddCommand(&cobra.Command{
		Use: "template", Short: "Print the built-in rendered template", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			_, err := fmt.Fprint(cmd.OutOrStdout(), tmuxconfig.Template(store.Root()))
			return err
		},
	})
	var file string
	checkCmd := &cobra.Command{
		Use: "check", Short: "Validate a config on a private tmux socket", Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			label, err := tmux.EffectiveLabel()
			if err != nil {
				return err
			}
			if file == "" {
				file = tmuxconfig.Paths(store.Root()).Config
			}
			errors, err := tmuxconfig.Check(cmd.Context(), file)
			if err != nil {
				return err
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(struct {
				OK             bool     `json:"ok"`
				Errors         []string `json:"errors"`
				EffectiveLabel string   `json:"effective_label"`
			}{OK: len(errors) == 0, Errors: errors, EffectiveLabel: label})
		},
	}
	checkCmd.Flags().StringVar(&file, "file", "", "config file to validate")
	configCmd.AddCommand(checkCmd)
	tmuxCmd.AddCommand(configCmd)
	return tmuxCmd
}
