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
	var days int

	cmd := &cobra.Command{
		Use:   "prune",
		Short: "Remove stale party manifests older than a threshold",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPrune(cmd.Context(), cmd.OutOrStdout(), store, client, days)
		},
	}
	cmd.Flags().IntVar(&days, "days", defaultPruneDays, "max age in days before pruning")
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
