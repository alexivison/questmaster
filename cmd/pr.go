package cmd

import (
	"context"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func newPRCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var sessionFlag string
	cmd := &cobra.Command{Use: "pr", Short: "Manage watched pull requests"}
	cmd.PersistentFlags().StringVar(&sessionFlag, "session", "", "session ID (defaults to current session)")
	resolve := func(ctx context.Context) (string, error) {
		id, err := resolveArtifactSession(ctx, client, sessionFlag)
		if err != nil {
			return "", err
		}
		if _, err := store.Read(id); err != nil {
			return "", fmt.Errorf("session %s has no live manifest: %w", id, err)
		}
		return id, nil
	}
	cmd.AddCommand(&cobra.Command{
		Use: "watch <ref>", Short: "Watch a pull request", Args: cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			id, err := resolve(c.Context())
			if err != nil {
				return err
			}
			ref, err := state.ParsePullRequestRef(args[0])
			if err != nil {
				return err
			}
			added, err := state.WatchPullRequest(store.Root(), id, ref, time.Now())
			if err != nil {
				return err
			}
			return writeJSON(c.OutOrStdout(), struct {
				Key       string `json:"key"`
				SessionID string `json:"session_id"`
				Added     bool   `json:"added"`
			}{ref.Key, id, added})
		},
	})
	cmd.AddCommand(&cobra.Command{
		Use: "unwatch <ref>", Short: "Stop watching a pull request", Args: cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			id, err := resolve(c.Context())
			if err != nil {
				return err
			}
			ref, err := state.ParsePullRequestRef(args[0])
			if err != nil {
				return err
			}
			removed, err := state.UnwatchPullRequest(store.Root(), id, ref.Key)
			if err != nil {
				return err
			}
			return writeJSON(c.OutOrStdout(), struct {
				Key       string `json:"key"`
				SessionID string `json:"session_id"`
				Removed   bool   `json:"removed"`
			}{ref.Key, id, removed})
		},
	})
	var all bool
	ls := &cobra.Command{
		Use: "ls", Short: "List watched pull requests", Args: cobra.NoArgs,
		RunE: func(c *cobra.Command, _ []string) error {
			var scope map[string]bool
			if !all || sessionFlag != "" {
				id, err := resolve(c.Context())
				if err != nil {
					return err
				}
				if !all {
					scope = map[string]bool{id: true}
				}
			}
			prs, err := state.LivePullRequests(store, scope)
			if err != nil {
				return err
			}
			return writeJSON(c.OutOrStdout(), prs)
		},
	}
	ls.Flags().BoolVar(&all, "all", false, "list all watched pull requests")
	cmd.AddCommand(ls)
	return cmd
}
