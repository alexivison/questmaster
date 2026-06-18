package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

const defaultPruneDays = 7

type pruneResult struct {
	Days   int      `json:"days"`
	DryRun bool     `json:"dry_run"`
	Pruned int      `json:"pruned"`
	Paths  []string `json:"paths,omitempty"`
}

func newPruneCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var (
		days   int
		dryRun bool
	)

	cmd := &cobra.Command{
		Use:   "prune",
		Short: "Remove stale questmaster session manifests",
		RunE: func(cmd *cobra.Command, _ []string) error {
			result, err := pruneManifests(cmd.Context(), store, client, days, dryRun)
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), result)
		},
	}
	cmd.Flags().IntVar(&days, "days", defaultPruneDays, "max age in days before pruning")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show what would be deleted without deleting")
	return cmd
}

func pruneManifests(ctx context.Context, store *state.Store, client *tmux.Client, maxDays int, dryRun bool) (pruneResult, error) {
	result := pruneResult{Days: maxDays, DryRun: dryRun}
	live, err := client.ListSessions(ctx)
	if err != nil {
		return result, fmt.Errorf("list tmux sessions: %w", err)
	}
	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		if state.IsValidSessionID(s) {
			liveSet[s] = true
		}
	}

	// Walk files directly (not DiscoverSessions) so corrupt manifests are eligible.
	root := store.Root()
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return result, nil
		}
		return result, fmt.Errorf("read state dir: %w", err)
	}

	cutoff := time.Now().Add(-time.Duration(maxDays) * 24 * time.Hour)

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".lock") {
			continue
		}
		sessionID := strings.TrimSuffix(name, ".json")
		if !state.IsValidSessionID(sessionID) {
			continue
		}
		if liveSet[sessionID] {
			continue
		}

		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().After(cutoff) {
			continue
		}

		// Try to parse manifest for master-with-workers guard; skip on parse failure (prune it).
		m, readErr := store.Read(sessionID)
		if readErr == nil && m.SessionType == "master" && len(m.Workers) > 0 {
			continue
		}

		path := filepath.Join(root, name)
		if dryRun {
			result.Paths = append(result.Paths, path)
			result.Pruned++
			continue
		}

		// Deregister from parent before deleting manifest.
		if readErr == nil {
			parent := m.ExtraString("parent_session")
			if parent != "" {
				_ = store.RemoveWorker(parent, sessionID)
			}
		}

		if err := os.Remove(path); err != nil {
			continue
		}
		result.Paths = append(result.Paths, path)
		result.Pruned++
	}
	return result, nil
}
