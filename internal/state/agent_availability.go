//go:build linux || darwin

package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// AgentAvailabilityFile is the basename of the agent availability preference
// file under the shared state root.
const AgentAvailabilityFile = "agent-availability.json"

// AgentAvailabilityStore persists per-agent launch permission. Entries absent
// from the file are enabled, so a missing file preserves the historical
// behavior for every built-in agent.
type AgentAvailabilityStore struct {
	path string
}

// NewAgentAvailabilityStore returns a store backed by
// <root>/agent-availability.json.
func NewAgentAvailabilityStore(root string) *AgentAvailabilityStore {
	return &AgentAvailabilityStore{path: filepath.Join(root, AgentAvailabilityFile)}
}

// Load returns only the explicit per-agent settings. A missing file means
// every agent is enabled.
func (s *AgentAvailabilityStore) Load() (map[string]bool, error) {
	return s.loadFrom()
}

// Enabled reports whether name is enabled. An agent with no saved setting is
// enabled by default.
func (s *AgentAvailabilityStore) Enabled(name string) (bool, error) {
	settings, err := s.Load()
	if err != nil {
		return false, err
	}
	enabled, ok := settings[name]
	if !ok {
		return true, nil
	}
	return enabled, nil
}

// Set updates one agent while preserving every other setting. Writers hold a
// sibling flock through read, write and atomic replacement so concurrent
// toggles cannot overwrite one another.
func (s *AgentAvailabilityStore) Set(name string, enabled bool) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return fmt.Errorf("agent is required")
	}
	return s.withLock(func() error {
		settings, err := s.loadFrom()
		if err != nil {
			return err
		}
		settings[name] = enabled
		return s.writeLocked(settings)
	})
}

func (s *AgentAvailabilityStore) loadFrom() (map[string]bool, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]bool{}, nil
		}
		return nil, fmt.Errorf("read agent availability: %w", err)
	}
	var settings map[string]bool
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, fmt.Errorf("parse agent availability: %w", err)
	}
	if settings == nil {
		settings = map[string]bool{}
	}
	return settings, nil
}

func (s *AgentAvailabilityStore) writeLocked(settings map[string]bool) error {
	data, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal agent availability: %w", err)
	}
	data = append(data, '\n')

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write agent availability temp file: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("replace agent availability: %w", err)
	}
	return nil
}

func (s *AgentAvailabilityStore) withLock(fn func() error) error {
	if err := EnsurePrivateStateRoot(filepath.Dir(s.path)); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	f, err := os.OpenFile(s.path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return fmt.Errorf("open agent availability lock: %w", err)
	}
	defer f.Close()
	if err := acquireFlock(f); err != nil {
		return fmt.Errorf("acquire agent availability lock: %w", err)
	}
	defer releaseFlock(f)
	return fn()
}
