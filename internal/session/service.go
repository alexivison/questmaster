// Package session manages lifecycle operations (start, delete, continue, spawn).
//
// Lifecycle locks: Start, Continue and Delete run their check, create, set-up
// and delete steps while holding the session's lifecycle lock
// (state.Store.WithLifecycleLock), so two operations on one session never
// interleave. A worker's Start and Continue also hold its master's lock through
// registering and launching the worker, and a master's Delete holds its own
// lock through the cascade over its workers, so no worker is registered or
// launched around that cascade. Locks are taken parent first, then child, and
// nothing that holds a child's lock takes its parent's. A master's Continue
// cascades to its workers after releasing its own lock; each worker's Continue
// then takes the locks itself. The steps under the locks share one deadline
// (defaultLifecycleTimeout), so a tmux server that stops answering holds the
// locks only that long.
package session

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/config"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Service provides session lifecycle operations backed by state and tmux.
type Service struct {
	Store    *state.Store
	Client   *tmux.Client
	RepoRoot string
	Registry *agent.Registry
	// ReasoningEfforts resolves model-specific levels before launch using the
	// resolved CLI binary.
	ReasoningEfforts func(context.Context, string, string, string) []string
	RandClassIndex   func(int) int

	// CLIResolver resolves the questmaster launch command. Defaults to config.ResolveQuestmasterCmd.
	CLIResolver func(repoRoot string) (string, error)
	// Now returns the current unix timestamp. Defaults to time.Now().Unix().
	Now func() int64
	// RandSuffix returns a random int for session ID dedup.
	RandSuffix func() int64

	// lifecycleTimeout overrides defaultLifecycleTimeout in tests.
	lifecycleTimeout time.Duration
}

const (
	// defaultLifecycleTimeout bounds the steps one lifecycle operation runs under
	// its locks.
	defaultLifecycleTimeout = 30 * time.Second
	// rollbackTimeout bounds a rollback, which runs even after the lifecycle
	// deadline has passed.
	rollbackTimeout = 5 * time.Second
)

// locked runs fn under the lifecycle locks of ids, taken in order (a master
// before its worker; empty ids are skipped). fn's context carries the lifecycle
// deadline, which starts once every lock is held.
func (s *Service) locked(ctx context.Context, ids []string, fn func(context.Context) error) error {
	if len(ids) == 0 {
		timeout := s.lifecycleTimeout
		if timeout == 0 {
			timeout = defaultLifecycleTimeout
		}
		ctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		return fn(ctx)
	}
	if ids[0] == "" {
		return s.locked(ctx, ids[1:], fn)
	}
	return s.Store.WithLifecycleLock(ids[0], func() error {
		return s.locked(ctx, ids[1:], fn)
	})
}

// rollbackContext keeps a rollback running after the lifecycle deadline that
// may have caused it, under a deadline of its own.
func rollbackContext(ctx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(ctx), rollbackTimeout)
}

// NewService creates a session service with production defaults.
func NewService(store *state.Store, client *tmux.Client, repoRoot string, registry ...*agent.Registry) *Service {
	svc := &Service{
		Store:          store,
		Client:         client,
		RepoRoot:       repoRoot,
		CLIResolver:    config.ResolveQuestmasterCmd,
		Now:            func() int64 { return time.Now().Unix() },
		RandSuffix:     func() int64 { return rand.Int64N(100000) },
		RandClassIndex: rand.IntN,
	}
	if len(registry) > 0 {
		svc.Registry = registry[0]
	}
	return svc
}

// runtimeDir returns the runtime directory path for a session.
// Uses /tmp/ (not os.TempDir()) so runtime cleanup sees the same stable path
// on macOS, where os.TempDir() returns a per-user /var/folders/... location.
func runtimeDir(sessionID string) string {
	return filepath.Join("/tmp", sessionID)
}

// ensureRuntimeDir creates the runtime directory and writes the session name file.
func ensureRuntimeDir(sessionID string) (string, error) {
	dir := runtimeDir(sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create runtime dir: %w", err)
	}
	nameFile := filepath.Join(dir, "session-name")
	if err := os.WriteFile(nameFile, []byte(sessionID+"\n"), 0o644); err != nil {
		return "", fmt.Errorf("write session-name: %w", err)
	}
	return dir, nil
}

// removeRuntimeDir removes the runtime directory for a session.
func removeRuntimeDir(sessionID string) {
	os.RemoveAll(runtimeDir(sessionID))
}

// sessionRole identifies a session's role for agent launch behavior.
type sessionRole string

const (
	roleMaster sessionRole = "master"
	roleWorker sessionRole = "worker"
)

func agentSessionRole(role sessionRole) agent.SessionRole {
	switch role {
	case roleMaster:
		return agent.RoleMaster
	case roleWorker:
		return agent.RoleWorker
	default:
		return agent.RoleMaster
	}
}

// roleForManifest derives a managed role from the manifest's agent and parent fields.
func roleForManifest(m state.Manifest) sessionRole {
	switch m.AgentSessionType() {
	case "master":
		return roleMaster
	case "worker":
		return roleWorker
	default:
		return ""
	}
}

func (s *Service) agentRegistry() (*agent.Registry, error) {
	if s.Registry != nil {
		return s.Registry, nil
	}
	registry, err := agent.NewRegistry(agent.DefaultConfig())
	if err != nil {
		return nil, err
	}
	s.Registry = registry
	return registry, nil
}

// TODO(layering): these two helpers are free functions parked in
// service.go because they're shared across session operations but belong
// to neither the Service type nor any single caller. Move to a
// session/errors.go file once there's a third helper worth grouping, or
// push validateSessionID down to the state package next to
// IsValidSessionID (the canonical source of the rule).

// validateSessionID rejects IDs that don't match supported questmaster session IDs.
func validateSessionID(sessionID string) error {
	if !state.IsValidSessionID(sessionID) {
		return fmt.Errorf("invalid session name %q (expected qm-*)", sessionID)
	}
	return nil
}

// isManifestNotFound returns true if the error indicates the manifest
// doesn't exist. This is expected during cleanup when another process
// already removed it) and should not be treated as a failure.
func isManifestNotFound(err error) bool {
	return errors.Is(err, state.ErrManifestNotFound)
}
