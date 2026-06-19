//go:build linux || darwin

package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/workspace"
	"github.com/spf13/cobra"
)

func newItemCmd(store *state.Store) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "item",
		Short: "Create and list workspace items",
		Args:  cobra.NoArgs,
	}
	cmd.AddCommand(
		newItemCreateCmd(store),
		newItemLsCmd(store),
	)
	return cmd
}

func newItemCreateCmd(store *state.Store) *cobra.Command {
	var itemType, title, artifactPath, inline string
	cmd := &cobra.Command{
		Use:   "create --type <type> --title <title> (--path <path> | --inline <content>)",
		Short: "Create a workspace item manifest under the state root",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			artifact, err := artifactFromFlags(cmd, artifactPath, inline)
			if err != nil {
				return err
			}
			item, err := workspace.NewStore(store.Root()).Create(workspace.CreateInput{
				Type:     itemType,
				Title:    title,
				Artifact: artifact,
			})
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), item)
		},
	}
	cmd.Flags().StringVar(&itemType, "type", "", "workspace item type tag")
	cmd.Flags().StringVar(&title, "title", "", "workspace item title")
	cmd.Flags().StringVar(&artifactPath, "path", "", "artifact file path to reference")
	cmd.Flags().StringVar(&inline, "inline", "", "inline artifact content")
	return cmd
}

func newItemLsCmd(store *state.Store) *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List workspace items",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			items, err := workspace.OpenStore(store.Root()).List()
			if err != nil {
				return err
			}
			quests, err := quest.DefaultStore().List()
			if err != nil {
				return err
			}
			if items == nil {
				items = []workspace.Item{}
			}
			return writeJSON(cmd.OutOrStdout(), struct {
				Items []workspace.ListedItem `json:"items"`
			}{Items: workspace.WithAttachmentUsage(items, quests)})
		},
	}
}

func artifactFromFlags(cmd *cobra.Command, artifactPath, inline string) (workspace.Artifact, error) {
	pathSet := cmd.Flags().Changed("path")
	inlineSet := cmd.Flags().Changed("inline")
	switch {
	case pathSet && inlineSet:
		return workspace.Artifact{}, fmt.Errorf("item artifact accepts only one of --path or --inline")
	case !pathSet && !inlineSet:
		return workspace.Artifact{}, fmt.Errorf("item create requires --path or --inline")
	case inlineSet:
		return workspace.Artifact{Inline: inline}, nil
	default:
		abs, err := filepath.Abs(artifactPath)
		if err != nil {
			return workspace.Artifact{}, fmt.Errorf("resolve item path: %w", err)
		}
		if _, err := os.Stat(abs); err != nil {
			return workspace.Artifact{}, fmt.Errorf("stat item path: %w", err)
		}
		return workspace.Artifact{Path: abs}, nil
	}
}
