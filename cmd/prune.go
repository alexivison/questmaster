package cmd

import (
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

const defaultPruneDays = 7

func newPruneCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	var (
		days      int
		artifacts bool
		dryRun    bool
	)

	cmd := &cobra.Command{
		Use:   "prune",
		Short: "Remove stale party manifests and optionally session artifacts",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := runPrune(cmd.Context(), cmd.OutOrStdout(), store, client, days); err != nil {
				return err
			}
			if artifacts {
				return runPruneArtifacts(cmd.OutOrStdout(), days, dryRun)
			}
			return nil
		},
	}
	cmd.Flags().IntVar(&days, "days", defaultPruneDays, "max age in days before pruning")
	cmd.Flags().BoolVar(&artifacts, "artifacts", false, "also prune session artifacts (projects history, shell snapshots, empty logs)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "show what would be deleted without deleting (artifacts only)")
	return cmd
}

func runPrune(ctx context.Context, w io.Writer, store *state.Store, client *tmux.Client, maxDays int) error {
	live, err := client.ListSessions(ctx)
	if err != nil {
		return fmt.Errorf("list tmux sessions: %w", err)
	}
	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		if strings.HasPrefix(s, "party-") {
			liveSet[s] = true
		}
	}

	// Walk files directly (not DiscoverSessions) so corrupt manifests are eligible.
	root := store.Root()
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read state dir: %w", err)
	}

	cutoff := time.Now().Add(-time.Duration(maxDays) * 24 * time.Hour)
	pruned := 0

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".lock") {
			continue
		}
		partyID := strings.TrimSuffix(name, ".json")
		if !strings.HasPrefix(partyID, "party-") {
			continue
		}
		if liveSet[partyID] {
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
		m, readErr := store.Read(partyID)
		if readErr == nil && m.SessionType == "master" && len(m.Workers) > 0 {
			continue
		}

		path := filepath.Join(root, name)
		if err := os.Remove(path); err != nil {
			continue
		}
		pruned++
	}

	if pruned > 0 {
		fmt.Fprintf(w, "Pruned %d party manifest(s) older than %d days.\n", pruned, maxDays)
	}
	return nil
}

// runPruneArtifacts cleans up session artifacts beyond manifests:
//   - ~/.claude/projects/ directories older than threshold
//   - codex/shell_snapshots/ older than 60 days
//   - Empty log files under ~/.claude/logs/
func runPruneArtifacts(w io.Writer, maxDays int, dryRun bool) error {
	home := os.Getenv("HOME")
	if home == "" {
		return fmt.Errorf("HOME not set")
	}

	var totalPruned int64

	// 1. Claude projects session history (oldest dirs)
	projectsDays := maxDays
	if projectsDays < 30 {
		projectsDays = 30 // minimum 30 days for project history
	}
	pruned, err := pruneOldEntries(filepath.Join(home, ".claude", "projects"), projectsDays, true, dryRun, w)
	if err != nil {
		fmt.Fprintf(w, "Warning: projects prune: %v\n", err)
	}
	totalPruned += pruned

	// 2. Codex shell snapshots (older than 60 days)
	snapshotDays := 60
	pruned, err = pruneOldEntries(filepath.Join(home, ".codex", "shell_snapshots"), snapshotDays, false, dryRun, w)
	if err != nil {
		fmt.Fprintf(w, "Warning: shell_snapshots prune: %v\n", err)
	}
	totalPruned += pruned

	// 3. Empty log files
	pruned, err = pruneEmptyFiles(filepath.Join(home, ".claude", "logs"), dryRun, w)
	if err != nil {
		fmt.Fprintf(w, "Warning: logs prune: %v\n", err)
	}
	totalPruned += pruned

	if totalPruned > 0 {
		verb := "Pruned"
		if dryRun {
			verb = "Would prune"
		}
		fmt.Fprintf(w, "%s %d artifact(s).\n", verb, totalPruned)
	} else {
		fmt.Fprintln(w, "No artifacts to prune.")
	}
	return nil
}

// pruneOldEntries removes entries older than maxDays from root.
// If dirsOnly is true, only directories are pruned; otherwise only files.
func pruneOldEntries(root string, maxDays int, dirsOnly bool, dryRun bool, w io.Writer) (int64, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}

	cutoff := time.Now().Add(-time.Duration(maxDays) * 24 * time.Hour)
	var count int64

	for _, e := range entries {
		if dirsOnly != e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.ModTime().After(cutoff) {
			continue
		}

		path := filepath.Join(root, e.Name())
		if dryRun {
			fmt.Fprintf(w, "  [dry-run] rm %s\n", path)
		} else {
			rmFn := os.Remove
			if dirsOnly {
				rmFn = os.RemoveAll
			}
			if err := rmFn(path); err != nil {
				continue
			}
		}
		count++
	}
	return count, nil
}

// pruneEmptyFiles removes zero-byte files from root.
func pruneEmptyFiles(root string, dryRun bool, w io.Writer) (int64, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}

	var count int64
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if info.Size() > 0 {
			continue
		}

		path := filepath.Join(root, e.Name())
		if dryRun {
			fmt.Fprintf(w, "  [dry-run] rm %s (empty)\n", path)
		} else {
			if err := os.Remove(path); err != nil {
				continue
			}
		}
		count++
	}
	return count, nil
}
