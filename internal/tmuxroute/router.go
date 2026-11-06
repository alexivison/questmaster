// Package tmuxroute pins session operations to the server recorded in their
// manifests and inventories the legacy and dedicated tmux servers.
package tmuxroute

import (
	"context"
	"fmt"
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
	store     *state.Store
	creation  func() string
	paths     []string
	refreshMu sync.Mutex
	mu        sync.Mutex
	clients   map[string]*tmux.Client
	cache     map[string]cacheEntry
	factory   func(string) (*tmux.Client, error)
}

func New(store *state.Store, clients map[string]*tmux.Client, creation func() string, namedConfigFiles []string) *Router {
	copyClients := make(map[string]*tmux.Client, len(clients))
	for label, client := range clients {
		copyClients[label] = client
	}
	return &Router{store: store, clients: copyClients, creation: creation, paths: append([]string(nil), namedConfigFiles...), cache: make(map[string]cacheEntry)}
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
	if tmux.DefaultServer().Label() != "default" {
		defaultClient = tmux.NewClient(tmux.LegacyServer())
	}
	paths := tmuxconfig.Paths(root)
	files := []string{paths.Config, paths.Enforced}
	named, err := tmux.NamedServerLabel(label, files[0], files[1])
	if err != nil {
		return nil, err
	}
	r := New(state.OpenStore(root), map[string]*tmux.Client{"default": defaultClient, label: tmux.NewClient(named)}, func() string { return tmux.DefaultServer().Label() }, files)
	r.factory = func(recorded string) (*tmux.Client, error) {
		server, err := tmux.NamedServerLabel(recorded, files[0], files[1])
		if err != nil {
			return nil, err
		}
		return tmux.NewClient(server), nil
	}
	return r, nil
}

func (r *Router) handle(label string) (Handle, error) {
	if label != "default" {
		if err := tmux.ValidateNamedLabel(label); err != nil {
			return Handle{}, err
		}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	client := r.clients[label]
	if client == nil && r.factory != nil && label != "default" {
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
	if label != "default" {
		h.configFiles = append([]string(nil), r.paths...)
	}
	return h, nil
}

func (r *Router) Route(m state.Manifest) (Handle, error) {
	label := string(m.TmuxServer)
	if label == "" {
		label = "default"
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
