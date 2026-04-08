package cmd

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newListCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List party sessions (active and resumable)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runList(cmd.Context(), cmd.OutOrStdout(), store, client)
		},
	}
}

func runList(ctx context.Context, w io.Writer, store *state.Store, client *tmux.Client) error {
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

	all, err := store.DiscoverSessions()
	if err != nil {
		return fmt.Errorf("discover sessions: %w", err)
	}

	// Index manifests by ID for O(1) lookup.
	manifestIdx := make(map[string]state.Manifest, len(all))
	for _, m := range all {
		manifestIdx[m.PartyID] = m
	}

	// Build active list in tmux order (preserves shell semantics).
	var active []state.Manifest
	for _, id := range live {
		if !strings.HasPrefix(id, "party-") {
			continue
		}
		if m, ok := manifestIdx[id]; ok {
			active = append(active, m)
		} else {
			active = append(active, state.Manifest{PartyID: id})
		}
	}

	// Stale: manifests not live in tmux.
	var stale []state.Manifest
	for _, m := range all {
		if !liveSet[m.PartyID] {
			stale = append(stale, m)
		}
	}

	if len(active) == 0 && len(stale) == 0 {
		fmt.Fprintln(w, "No party sessions found.")
		return nil
	}

	if len(active) > 0 {
		fmt.Fprintln(w, "Active:")
		for _, m := range active {
			printSessionLine(w, m)
		}
	}

	if len(stale) > 0 {
		// Sort by mtime descending (newest first), matching shell behavior
		state.SortByMtime(stale, store.Root())

		fmt.Fprintln(w, "Resumable (--continue <id>):")
		limit := len(stale)
		if limit > 10 {
			limit = 10
		}
		for _, m := range stale[:limit] {
			printSessionLine(w, m)
		}
	}

	return nil
}

func printSessionLine(w io.Writer, m state.Manifest) {
	var parts []string
	parts = append(parts, m.PartyID)
	if m.Title != "" {
		parts = append(parts, "("+m.Title+")")
	}
	if m.Cwd != "" {
		parts = append(parts, m.Cwd)
	}
	fmt.Fprintf(w, "  %s\n", strings.Join(parts, "  "))
}
