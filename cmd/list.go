package cmd

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
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

func newListCmd(store *state.Store, client *tmux.Client, router *tmuxroute.Router, routerErr error) *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List questmaster sessions (active and resumable)",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if routerErr != nil {
				return fmt.Errorf("tmux router: %w", routerErr)
			}
			result, err := collectList(cmd.Context(), store, client, router)
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

func collectList(ctx context.Context, store *state.Store, client *tmux.Client, routers ...*tmuxroute.Router) (listResult, error) {
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
	if router == nil {
		return listResult{}, fmt.Errorf("tmux router is required for list")
	}
	inv := router.Inventory(ctx)
	for _, server := range inv.Servers {
		if server.Outcome == tmuxroute.Unavailable {
			return listResult{}, fmt.Errorf("tmux server %s unavailable: %s", server.Label, server.Error)
		}
	}
	liveSet := make(map[string]bool, len(inv.Rows))
	for _, row := range inv.Rows {
		liveSet[row.Label+"\x00"+row.ID] = true
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
	for _, row := range inv.Rows {
		id := row.ID
		if !state.IsValidSessionID(id) {
			continue
		}
		if m, ok := manifestIdx[id]; ok {
			h, err := router.Route(m)
			if err != nil {
				return listResult{}, err
			}
			if h.Label() == row.Label {
				active = append(active, m)
			}
		} else {
			active = append(active, state.Manifest{SessionID: id})
		}
	}

	// Stale: manifests not live in tmux.
	var stale []state.Manifest
	for _, m := range all {
		h, err := router.Route(m)
		if err != nil {
			return listResult{}, err
		}
		if !liveSet[h.Label()+"\x00"+m.SessionID] {
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
		SessionType: m.SessionRole(),
		Live:        live,
	}
}
