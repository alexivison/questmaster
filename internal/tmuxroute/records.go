package tmuxroute

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

// RouteRecord is the additive daemon and CLI wire shape.
type RouteRecord struct {
	SessionID   string   `json:"session_id"`
	Server      string   `json:"server"`
	ConfigFiles []string `json:"config_files"`
	Live        bool     `json:"live"`
	CreatedUnix int64    `json:"created_unix"`
}

// Routes reports recorded ownership and observed liveness. A conflict or an
// unavailable server prevents the caller from asserting a false live value.
func (r *Router) Routes(ctx context.Context, ids []string, liveOnly bool) ([]RouteRecord, error) {
	var manifests []state.Manifest
	if len(ids) == 0 {
		var err error
		manifests, err = r.store.DiscoverSessions()
		if err != nil {
			return nil, err
		}
		sort.Slice(manifests, func(i, j int) bool { return manifests[i].SessionID < manifests[j].SessionID })
	} else {
		seen := make(map[string]bool, len(ids))
		for _, id := range ids {
			if seen[id] {
				continue
			}
			seen[id] = true
			m, err := r.store.Read(id)
			if err != nil {
				return nil, fmt.Errorf("read %s: %w", id, err)
			}
			manifests = append(manifests, m)
		}
	}
	for _, m := range manifests {
		if _, err := r.Route(m); err != nil {
			return nil, fmt.Errorf("route %s: %w", m.SessionID, err)
		}
	}
	inv := r.Inventory(ctx)
	live := make(map[string]map[string]bool, len(inv.Servers))
	for _, s := range inv.Servers {
		if s.Outcome == Unavailable {
			return nil, fmt.Errorf("tmux server %s unavailable: %s", s.Label, s.Error)
		}
		live[s.Label] = make(map[string]bool)
	}
	for _, row := range inv.Rows {
		if row.Conflict {
			return nil, fmt.Errorf("session %s exists on multiple tmux servers", row.ID)
		}
		live[row.Label][row.ID] = true
	}
	records := make([]RouteRecord, 0, len(manifests))
	for _, m := range manifests {
		h, _ := r.Route(m)
		isLive := live[h.Label()][m.SessionID]
		if liveOnly && !isLive {
			continue
		}
		var created int64
		if m.CreatedAt != "" {
			t, err := time.Parse(time.RFC3339, m.CreatedAt)
			if err != nil {
				return nil, fmt.Errorf("invalid created_at for %s: %w", m.SessionID, err)
			}
			created = t.Unix()
		}
		records = append(records, RouteRecord{SessionID: m.SessionID, Server: h.Label(), ConfigFiles: h.ConfigFiles(), Live: isLive, CreatedUnix: created})
	}
	return records, nil
}

// Audit is a read-only removal gate. Unknown means evidence is incomplete;
// unavailable servers and corrupt ownership never count as zero.
type Audit struct {
	Gate              string            `json:"gate"`
	InventoryError    string            `json:"inventory_error,omitempty"`
	Servers           []ServerInventory `json:"servers"`
	LiveSessions      []Row             `json:"live_sessions"`
	LiveLegacyManaged []string          `json:"live_legacy_managed"`
	Orphans           []Row             `json:"orphans"`
	Duplicates        []string          `json:"duplicates"`
	UnknownOwnership  []string          `json:"unknown_ownership"`
	CorruptManifests  []string          `json:"corrupt_manifests"`
}

func (r *Router) Audit(ctx context.Context) (Audit, error) {
	inv, inventoryErr := r.CompleteInventory(ctx)
	a := Audit{Gate: "ready", Servers: inv.Servers, LiveSessions: inv.Rows, LiveLegacyManaged: []string{}, Orphans: []Row{}, Duplicates: []string{}, UnknownOwnership: []string{}, CorruptManifests: []string{}}
	if inventoryErr != nil {
		a.Gate = "unknown"
		a.InventoryError = inventoryErr.Error()
	}
	entries, err := os.ReadDir(r.store.Root())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return a, err
	}
	manifests := make(map[string]state.Manifest)
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".json") {
			continue
		}
		id := strings.TrimSuffix(name, ".json")
		if !state.IsValidSessionID(id) {
			continue
		}
		m, readErr := r.store.Read(id)
		if readErr != nil {
			a.CorruptManifests = append(a.CorruptManifests, id)
			a.Gate = "unknown"
			continue
		}
		manifests[id] = m
		if _, routeErr := r.Route(m); routeErr != nil {
			a.UnknownOwnership = append(a.UnknownOwnership, id)
			a.Gate = "unknown"
		}
	}
	seenDuplicates := make(map[string]bool)
	for _, row := range inv.Rows {
		if row.Conflict && !seenDuplicates[row.ID] {
			a.Duplicates = append(a.Duplicates, row.ID)
			seenDuplicates[row.ID] = true
		}
		if !state.HasSessionIDPrefix(row.ID) {
			continue
		}
		m, found := manifests[row.ID]
		if !found {
			if !contains(a.CorruptManifests, row.ID) {
				a.Orphans = append(a.Orphans, row)
			}
			continue
		}
		h, routeErr := r.Route(m)
		if routeErr != nil {
			continue
		}
		if h.Label() != row.Label {
			a.UnknownOwnership = append(a.UnknownOwnership, row.ID)
			a.Gate = "unknown"
			continue
		}
		if row.Label == "default" {
			a.LiveLegacyManaged = append(a.LiveLegacyManaged, row.ID)
		}
	}
	if a.Gate != "unknown" && (len(a.LiveLegacyManaged) > 0 || len(a.Orphans) > 0 || len(a.Duplicates) > 0) {
		a.Gate = "blocked"
	}
	sort.Strings(a.LiveLegacyManaged)
	sort.Strings(a.Duplicates)
	sort.Strings(a.UnknownOwnership)
	sort.Strings(a.CorruptManifests)
	return a, nil
}

func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
