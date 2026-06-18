package cmd

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

type listSessionJSON struct {
	SessionID   string `json:"session_id"`
	Title       string `json:"title,omitempty"`
	Cwd         string `json:"cwd,omitempty"`
	SessionType string `json:"session_type,omitempty"`
	Live        bool   `json:"live"`
}

type listJSONOutput struct {
	Active    []listSessionJSON `json:"active"`
	Resumable []listSessionJSON `json:"resumable"`
}

func newListCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List questmaster sessions (active and resumable)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			result, err := collectList(cmd.Context(), store, client)
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), listJSON(result))
		},
	}
}

type listResult struct {
	active []state.Manifest
	stale  []state.Manifest
}

func collectList(ctx context.Context, store *state.Store, client *tmux.Client) (listResult, error) {
	live, err := client.ListSessions(ctx)
	if err != nil {
		return listResult{}, fmt.Errorf("list tmux sessions: %w", err)
	}
	liveSet := make(map[string]bool, len(live))
	for _, s := range live {
		if state.IsValidSessionID(s) {
			liveSet[s] = true
		}
	}

	all, err := store.DiscoverSessions()
	if err != nil {
		return listResult{}, fmt.Errorf("discover sessions: %w", err)
	}

	// Index manifests by ID for O(1) lookup.
	manifestIdx := make(map[string]state.Manifest, len(all))
	for _, m := range all {
		manifestIdx[m.SessionID] = m
	}

	// Build active list in tmux order (preserves shell semantics).
	var active []state.Manifest
	for _, id := range live {
		if !state.IsValidSessionID(id) {
			continue
		}
		if m, ok := manifestIdx[id]; ok {
			active = append(active, m)
		} else {
			active = append(active, state.Manifest{SessionID: id})
		}
	}

	// Stale: manifests not live in tmux.
	var stale []state.Manifest
	for _, m := range all {
		if !liveSet[m.SessionID] {
			stale = append(stale, m)
		}
	}

	state.SortByMtime(stale, store.Root())
	return listResult{active: active, stale: stale}, nil
}

func listJSON(result listResult) listJSONOutput {
	out := listJSONOutput{
		Active:    make([]listSessionJSON, 0, len(result.active)),
		Resumable: make([]listSessionJSON, 0, len(result.stale)),
	}
	for _, m := range result.active {
		out.Active = append(out.Active, listManifestJSON(m, true))
	}
	for _, m := range result.stale {
		out.Resumable = append(out.Resumable, listManifestJSON(m, false))
	}
	return out
}

func listManifestJSON(m state.Manifest, live bool) listSessionJSON {
	return listSessionJSON{
		SessionID:   m.SessionID,
		Title:       m.Title,
		Cwd:         m.Cwd,
		SessionType: m.SessionType,
		Live:        live,
	}
}
