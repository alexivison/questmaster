package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

var prEnsure = daemon.Ensure
var prRequest = daemon.RequestPRRefresh

func prDaemonConfig(root string) daemon.Config {
	if home, err := os.UserHomeDir(); err == nil {
		link := filepath.Join(home, ".local", "bin", "questmaster")
		if path, err := filepath.EvalSymlinks(link); err == nil {
			return daemon.Config{Root: root, Executable: path}
		} else if _, err := os.Lstat(link); !os.IsNotExist(err) {
			return daemon.Config{Root: root, Executable: link}
		}
	}
	path, _ := os.Executable()
	return daemon.Config{Root: root, Executable: path}
}

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
			m, err := store.Read(id)
			if err != nil {
				return err
			}
			if len(m.Agents) == 0 {
				return fmt.Errorf("session %s has no agent (plain terminal session)", id)
			}
			ref, err := state.ParsePullRequestRef(args[0])
			if err != nil {
				return err
			}
			config := prDaemonConfig(store.Root())
			ensureCtx, cancel := context.WithTimeout(c.Context(), 10*time.Second)
			_, _ = prEnsure(ensureCtx, config)
			cancel()
			added, err := state.WatchPullRequest(store.Root(), id, ref, time.Now())
			if err != nil {
				return err
			}
			if added {
				_, _ = prRequest(c.Context(), config, []string{ref.Key}, false)
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
			statuses, err := state.LoadPullRequestStatuses(store.Root())
			if err != nil {
				return err
			}
			state.AttachPullRequestStatuses(prs, statuses)
			return writeJSON(c.OutOrStdout(), prs)
		},
	}
	ls.Flags().BoolVar(&all, "all", false, "list all watched pull requests")
	cmd.AddCommand(ls)
	var unread bool
	events := &cobra.Command{
		Use: "events <ref>", Short: "Read watched pull-request activity", Args: cobra.ExactArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			id, err := resolve(c.Context())
			if err != nil {
				return err
			}
			ref, err := state.ParsePullRequestRef(args[0])
			if err != nil {
				return err
			}
			items, err := state.ReadPullRequestEvents(store.Root(), ref.Key, id, unread)
			if err != nil {
				return err
			}
			return writeJSON(c.OutOrStdout(), items)
		},
	}
	events.Flags().BoolVar(&unread, "unread", false, "show unread events and mark them read")
	cmd.AddCommand(events)
	var refreshAll bool
	refresh := &cobra.Command{
		Use: "refresh [ref]", Short: "Refresh watched pull-request statuses", Args: cobra.MaximumNArgs(1),
		RunE: func(c *cobra.Command, args []string) error {
			var scope map[string]bool
			if !refreshAll || sessionFlag != "" {
				id, err := resolve(c.Context())
				if err != nil {
					return err
				}
				if !refreshAll {
					scope = map[string]bool{id: true}
				}
			}
			prs, err := state.LivePullRequests(store, scope)
			if err != nil {
				return err
			}
			if len(args) > 0 {
				ref, err := state.ParsePullRequestRef(args[0])
				if err != nil {
					return err
				}
				filtered := prs[:0]
				for _, pr := range prs {
					if pr.Key == ref.Key {
						filtered = append(filtered, pr)
					}
				}
				prs = filtered
			}
			keys := make([]string, 0, len(prs))
			for _, pr := range prs {
				keys = append(keys, pr.Key)
			}
			config := prDaemonConfig(store.Root())
			ensureCtx, cancel := context.WithTimeout(c.Context(), 10*time.Second)
			_, err = prEnsure(ensureCtx, config)
			cancel()
			if err != nil {
				return fmt.Errorf("PR refresh needs a running daemon: %w", err)
			}
			hosts, err := prRequest(c.Context(), config, keys, true)
			if err != nil {
				return err
			}
			statuses, err := state.LoadPullRequestStatuses(store.Root())
			if err != nil {
				return err
			}
			state.AttachPullRequestStatuses(prs, statuses)
			return writeJSON(c.OutOrStdout(), struct {
				PullRequests []state.PullRequest            `json:"pull_requests"`
				Hosts        map[string]prstatus.HostResult `json:"hosts"`
			}{prs, hosts})
		},
	}
	refresh.Flags().BoolVar(&refreshAll, "all", false, "refresh all watched pull requests")
	cmd.AddCommand(refresh)
	return cmd
}
