// Package tmuxroute pins session operations to the server recorded in their
// manifests and inventories dedicated tmux servers.
package tmuxroute

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

// Handle is an immutable routing decision. Callers retain it through an
// operation, including its send-lock namespace.
type Handle struct {
	label       string
	client      *tmux.Client
	configFiles []string
}

func (h Handle) Label() string             { return h.label }
func (h Handle) Client() *tmux.Client      { return h.client }
func (h Handle) SendLockNamespace() string { return h.label }
func (h Handle) ConfigFiles() []string     { return append([]string{}, h.configFiles...) }

func (h Handle) Command(ctx context.Context, args ...string) (*exec.Cmd, error) {
	if len(h.configFiles) != 2 {
		return nil, fmt.Errorf("tmux server %q has no config files", h.label)
	}
	server, err := tmux.NamedServerLabel(h.label, h.configFiles[0], h.configFiles[1])
	if err != nil {
		return nil, err
	}
	return server.Command(ctx, args...), nil
}

type Outcome string

const (
	Available   Outcome = "available"
	Absent      Outcome = "absent"
	Unavailable Outcome = "unavailable"
)

type ServerInventory struct {
	Label   string  `json:"server"`
	Outcome Outcome `json:"outcome"`
	Error   string  `json:"error,omitempty"`
}

type Row struct {
	Label    string `json:"server"`
	ID       string `json:"session_id"`
	Conflict bool   `json:"conflict,omitempty"`
}

type Inventory struct {
	Servers []ServerInventory `json:"servers"`
	Rows    []Row             `json:"rows"`
}

type cacheEntry struct {
	at     time.Time
	server ServerInventory
	rows   []Row
}

// Router has one client per label. Production's factory creates a client for
// a recorded dev label without consulting today's environment override.
type Router struct {
	store          *state.Store
	creation       func() string
	paths          []string
	configRoot     string // nonempty only for production's per-label config paths
	refreshMu      sync.Mutex
	mu             sync.Mutex
	clients        map[string]*tmux.Client
	cache          map[string]cacheEntry
	factory        func(string) (*tmux.Client, error)
	defaultProbe   func(context.Context) ([]string, bool, error)
	labelRecordErr error
}

func New(store *state.Store, clients map[string]*tmux.Client, creation func() string, namedConfigFiles []string) *Router {
	copyClients := make(map[string]*tmux.Client, len(clients))
	for label, client := range clients {
		// A default client is accepted only as a read-only audit probe.
		if label != "default" {
			copyClients[label] = client
		}
	}
	r := &Router{store: store, clients: copyClients, creation: creation, paths: append([]string(nil), namedConfigFiles...), cache: make(map[string]cacheEntry)}
	if client := clients["default"]; client != nil {
		r.defaultProbe = client.ListSessionsStatus
	}
	return r
}

// NewProduction builds the dedicated client exactly once here. All other
// packages receive this router; no other production code selects its socket.
func NewProduction(store *state.Store, defaultClient *tmux.Client) (*Router, error) {
	root, err := filepath.Abs(store.Root())
	if err != nil {
		return nil, err
	}
	label, err := tmux.EffectiveLabel()
	if err != nil {
		return nil, err
	}
	paths := tmuxconfig.PathsForLabel(root, label)
	files := []string{paths.Config, paths.Enforced}
	// Preserve the caller's send deadline on every dedicated client.
	sendTimeout := defaultClient.SendTimeout
	newClient := func(runner tmux.Runner) *tmux.Client {
		client := tmux.NewClient(runner)
		client.SendTimeout = sendTimeout
		return client
	}
	named, err := tmux.NamedServerLabel(label, files[0], files[1])
	if err != nil {
		return nil, err
	}
	r := New(state.OpenStore(root), map[string]*tmux.Client{label: newClient(named)}, func() string { return label }, files)
	r.defaultProbe = tmux.ProbeDefaultSessions
	r.configRoot = root
	r.factory = func(recorded string) (*tmux.Client, error) {
		recordedPaths := tmuxconfig.PathsForLabel(root, recorded)
		server, err := tmux.NamedServerLabel(recorded, recordedPaths.Config, recordedPaths.Enforced)
		if err != nil {
			return nil, err
		}
		return newClient(server), nil
	}
	r.refreshPersistedLabels()
	return r, nil
}

func (r *Router) refreshPersistedLabels() {
	if r.store == nil {
		return
	}
	labels, err := state.ReadTmuxServerLabels(r.store.Root())
	if err == nil {
		for _, label := range labels {
			if _, err = r.handle(label); err != nil {
				break
			}
		}
	}
	r.mu.Lock()
	r.labelRecordErr = err
	r.mu.Unlock()
}

func (r *Router) handle(label string) (Handle, error) {
	if err := tmux.ValidateNamedLabel(label); err != nil {
		return Handle{}, err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	client := r.clients[label]
	if client == nil && r.factory != nil {
		var err error
		client, err = r.factory(label)
		if err != nil {
			return Handle{}, err
		}
		r.clients[label] = client
	}
	if client == nil {
		return Handle{}, fmt.Errorf("tmux server %q has no client", label)
	}
	h := Handle{label: label, client: client}
	if r.configRoot != "" {
		paths := tmuxconfig.PathsForLabel(r.configRoot, label)
		h.configFiles = []string{paths.Config, paths.Enforced}
	} else {
		h.configFiles = append([]string(nil), r.paths...)
	}
	return h, nil
}

func (r *Router) Route(m state.Manifest) (Handle, error) {
	label := string(m.TmuxServer)
	if label == "" {
		return Handle{}, fmt.Errorf("session %s is missing tmux_server; run qm tmux audit --backfill for stopped manifests", m.SessionID)
	}
	return r.handle(label)
}

func (r *Router) Creation() (Handle, error) { return r.handle(r.creation()) }

// KnownHandles returns clients already registered with the router. Caller
// discovery probes these only, without scanning the growing manifest set.
func (r *Router) KnownHandles() ([]Handle, error) {
	r.mu.Lock()
	labels := make([]string, 0, len(r.clients))
	for label := range r.clients {
		labels = append(labels, label)
	}
	r.mu.Unlock()
	sort.Strings(labels)
	handles := make([]Handle, 0, len(labels))
	for _, label := range labels {
		handle, err := r.handle(label)
		if err != nil {
			return nil, err
		}
		handles = append(handles, handle)
	}
	return handles, nil
}

// RecordedHandles adds every manifest's server before checking a ghost worker.
// An absent manifest cannot prove a worker is gone on a previously used label.
func (r *Router) RecordedHandles() ([]Handle, error) {
	if r.store != nil {
		manifests, err := r.store.DiscoverSessions()
		if err != nil {
			return nil, err
		}
		for _, m := range manifests {
			if m.TmuxServer != "" {
				if err := tmux.ValidateNamedLabel(string(m.TmuxServer)); err != nil {
					continue
				}
			}
			if _, err := r.Route(m); err != nil {
				return nil, err
			}
		}
	}
	return r.KnownHandles()
}

// Inventory asks each configured or recorded server once per second. Each
// call is individually bounded, and a missing socket is an absent outcome.
func (r *Router) Inventory(ctx context.Context) Inventory {
	r.refreshMu.Lock()
	defer r.refreshMu.Unlock()
	if r.store != nil {
		if manifests, err := r.store.DiscoverSessions(); err == nil {
			for _, m := range manifests {
				if tmux.ValidateNamedLabel(string(m.TmuxServer)) != nil {
					continue
				}
				_, _ = r.Route(m)
			}
		}
	}
	r.mu.Lock()
	labels := make([]string, 0, len(r.clients))
	for label := range r.clients {
		labels = append(labels, label)
	}
	r.mu.Unlock()
	sort.Strings(labels)
	result := Inventory{Servers: make([]ServerInventory, 0, len(labels)), Rows: []Row{}}
	for _, label := range labels {
		server, rows := r.inventoryServer(ctx, label)
		result.Servers = append(result.Servers, server)
		result.Rows = append(result.Rows, rows...)
	}
	counts := make(map[string]int, len(result.Rows))
	for _, row := range result.Rows {
		counts[row.ID]++
	}
	for i := range result.Rows {
		result.Rows[i].Conflict = counts[result.Rows[i].ID] > 1
	}
	return result
}

// Invalidate discards every server's cached observation after a lifecycle change.
func (r *Router) Invalidate() {
	r.refreshMu.Lock()
	defer r.refreshMu.Unlock()
	r.mu.Lock()
	clear(r.cache)
	r.mu.Unlock()
}

// CompleteInventory refreshes persisted labels and requires every server to
// answer. Incomplete discovery must never justify absence or clean ownership.
func (r *Router) CompleteInventory(ctx context.Context) (Inventory, error) {
	r.refreshPersistedLabels()
	r.mu.Lock()
	recordErr := r.labelRecordErr
	r.mu.Unlock()
	if recordErr != nil {
		return Inventory{Servers: []ServerInventory{}, Rows: []Row{}}, recordErr
	}
	inv := r.Inventory(ctx)
	for _, server := range inv.Servers {
		if server.Outcome == Unavailable {
			return inv, fmt.Errorf("tmux server %s unavailable: %s", server.Label, server.Error)
		}
	}
	return inv, nil
}

// LiveIDs returns the union of observed session names only when every server
// answered. Destructive callers must never treat unavailable as empty.
func (r *Router) LiveIDs(ctx context.Context) (map[string]bool, error) {
	inv, err := r.CompleteInventory(ctx)
	if err != nil {
		return nil, err
	}
	live := make(map[string]bool, len(inv.Rows))
	for _, row := range inv.Rows {
		live[row.ID] = true
	}
	return live, nil
}

func (r *Router) inventoryServer(ctx context.Context, label string) (ServerInventory, []Row) {
	r.mu.Lock()
	if entry, ok := r.cache[label]; ok && time.Since(entry.at) < time.Second {
		r.mu.Unlock()
		return entry.server, append([]Row(nil), entry.rows...)
	}
	client := r.clients[label]
	r.mu.Unlock()
	callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	ids, present, err := client.ListSessionsStatus(callCtx)
	server := ServerInventory{Label: label, Outcome: Available}
	if err != nil {
		server.Outcome = Unavailable
		server.Error = err.Error()
	} else if !present {
		server.Outcome = Absent
	}
	rows := make([]Row, 0, len(ids))
	if server.Outcome == Available {
		for _, id := range ids {
			rows = append(rows, Row{Label: label, ID: id})
		}
	}
	r.mu.Lock()
	r.cache[label] = cacheEntry{at: time.Now(), server: server, rows: rows}
	r.mu.Unlock()
	return server, rows
}
