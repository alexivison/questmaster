package cmd

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/spf13/cobra"
)

const defaultPruneDays = 7

type pruneResult struct {
	Days           int      `json:"days"`
	DryRun         bool     `json:"dry_run"`
	Pruned         int      `json:"pruned"`
	DroppedWatches int      `json:"dropped_watches"`
	Paths          []string `json:"paths,omitempty"`
}

func newPruneCmd(store *state.Store, client *tmux.Client, router *tmuxroute.Router, routerErr error) *cobra.Command {
	var (
		days   int
		dryRun bool
	)

	cmd := &cobra.Command{
		Use:   "prune",
		Short: "Remove stale session manifests and orphaned state and runtime directories",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if routerErr != nil {
				return fmt.Errorf("tmux router: %w", routerErr)
			}
			result, err := pruneManifests(cmd.Context(), store, client, days, dryRun, router)
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

func pruneManifests(ctx context.Context, store *state.Store, client *tmux.Client, maxDays int, dryRun bool, routers ...*tmuxroute.Router) (pruneResult, error) {
	if len(routers) == 0 || routers[0] == nil {
		return pruneResult{Days: maxDays, DryRun: dryRun}, fmt.Errorf("tmux router is required for prune")
	}
	legacyRoot := ""
	if filepath.Clean(store.Root()) == filepath.Clean(state.StateRoot()) {
		legacyRoot = "/tmp"
	}
	return pruneManifestsWithLegacyRoot(ctx, store, client, maxDays, dryRun, legacyRoot, routers...)
}

// legacyRoot is supplied by tests so they never scan or remove real /tmp paths.
func pruneManifestsWithLegacyRoot(ctx context.Context, store *state.Store, client *tmux.Client, maxDays int, dryRun bool, legacyRoot string, routers ...*tmuxroute.Router) (pruneResult, error) {
	result := pruneResult{Days: maxDays, DryRun: dryRun}
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
	if router == nil {
		return result, fmt.Errorf("tmux router is required for prune")
	}
	// Prune needs a fresh, complete view before its first mutation.
	router.Invalidate()
	liveSet, err := router.LiveIDs(ctx)
	if err != nil {
		return result, fmt.Errorf("list tmux sessions: %w", err)
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
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		if !state.IsValidSessionID(id) || liveSet[id] {
			continue
		}
		if _, err := store.Read(id); err != nil {
			return result, fmt.Errorf("cannot prune with unreadable session manifest %s: %w", id, err)
		}
	}

	cutoff := time.Now().Add(-time.Duration(maxDays) * 24 * time.Hour)
	wouldDelete := map[string]bool{}

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() {
			if !state.IsValidSessionID(name) || liveSet[name] {
				continue
			}
			if _, err := os.Lstat(filepath.Join(root, name+".json")); !os.IsNotExist(err) {
				continue
			}
			info, err := e.Info()
			if err != nil || info.ModTime().After(cutoff) {
				continue
			}
			path := filepath.Join(root, name)
			if !dryRun {
				if err := os.RemoveAll(path); err != nil {
					continue
				}
			}
			result.Paths = append(result.Paths, path)
			result.Pruned++
			continue
		}
		if !strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".lock") {
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

		// A manifest can become unreadable after the preflight scan.
		m, readErr := store.Read(sessionID)
		if readErr != nil {
			return result, fmt.Errorf("cannot prune with unreadable session manifest %s: %w", sessionID, readErr)
		}
		if m.AgentSessionType() == "master" && len(m.Workers) > 0 {
			continue
		}

		path := filepath.Join(root, name)
		if dryRun {
			wouldDelete[sessionID] = true
			result.Paths = append(result.Paths, path)
			result.Pruned++
			pruneRecordedRuntimeDir(&result, m, readErr, sessionID, legacyRoot, true)
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
		pruneRecordedRuntimeDir(&result, m, readErr, sessionID, legacyRoot, false)
	}
	for _, parent := range []struct {
		path   string
		legacy bool
	}{
		{path: filepath.Join(root, "runtime")},
		{path: legacyRoot, legacy: true},
	} {
		if parent.path == "" {
			continue
		}
		var info os.FileInfo
		if parent.legacy {
			// /tmp is a symlink on macOS; only this parent may be followed.
			info, err = os.Stat(parent.path)
		} else {
			info, err = os.Lstat(parent.path)
		}
		if err != nil || !info.IsDir() {
			continue
		}
		dirs, err := os.ReadDir(parent.path)
		if err != nil {
			return result, fmt.Errorf("read runtime dir %s: %w", parent.path, err)
		}
		for _, dir := range dirs {
			id := dir.Name()
			if !dir.IsDir() || !state.IsValidSessionID(id) || liveSet[id] {
				continue
			}
			if _, err := os.Lstat(filepath.Join(root, id+".json")); !os.IsNotExist(err) {
				continue
			}
			pruneRuntimePath(&result, filepath.Join(parent.path, id), dryRun)
		}
	}
	result.DroppedWatches, err = state.DropPullRequestWatches(root, func(id string) bool {
		if liveSet[id] {
			return false
		}
		if wouldDelete[id] {
			return true
		}
		_, err := store.Read(id)
		return err != nil
	}, dryRun)
	if err != nil {
		return result, err
	}
	if filepath.Clean(store.Root()) == filepath.Clean(state.StateRoot()) {
		home, err := os.UserHomeDir()
		if err != nil {
			return result, err
		}
		var agentPaths []string
		for sessionID := range liveSet {
			manifest, err := store.Read(sessionID)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				return result, nil
			} // Keep shims when a live session cannot be inspected.
			agentPaths = append(agentPaths, manifest.AgentPath)
		}
		paths, err := daemon.PruneLegacyShims(home, agentPaths, dryRun)
		if err != nil {
			return result, err
		}
		result.Paths = append(result.Paths, paths...)
		result.Pruned += len(paths)
	}
	return result, nil
}

func pruneRecordedRuntimeDir(result *pruneResult, m state.Manifest, readErr error, sessionID, legacyRoot string, dryRun bool) {
	if readErr != nil || m.SessionID != sessionID {
		return
	}
	dir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return
	}
	if m.RuntimeDir == "" {
		if legacyRoot == "" {
			return
		}
		dir = filepath.Join(legacyRoot, sessionID)
	}
	pruneRuntimePath(result, dir, dryRun)
}

func pruneRuntimePath(result *pruneResult, path string, dryRun bool) {
	removed, err := state.PruneRuntimeDir(path, dryRun)
	if err == nil && removed {
		result.Paths = append(result.Paths, path)
		result.Pruned++
	}
}
