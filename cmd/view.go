//go:build linux || darwin

package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/workspace"
	"github.com/spf13/cobra"
)

func newViewCmd() *cobra.Command {
	var explicitType string
	cmd := &cobra.Command{
		Use:   "view <path>",
		Short: "Resolve a file item and ask a running app viewer to open it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path, err := filepath.Abs(args[0])
			if err != nil {
				return fmt.Errorf("resolve view path: %w", err)
			}
			if _, err := os.Stat(path); err != nil {
				return fmt.Errorf("stat view path: %w", err)
			}
			item := serve.ActiveItem{
				Type:  workspace.InferType(path, explicitType),
				Title: filepath.Base(path),
				Path:  path,
			}
			serve.PublishActiveItemBestEffort(cmd.Context(), "", item)
			return writeJSON(cmd.OutOrStdout(), item)
		},
	}
	cmd.Flags().StringVar(&explicitType, "type", "", "explicit viewer type tag")
	return cmd
}
