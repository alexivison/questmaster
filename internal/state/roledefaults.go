//go:build linux || darwin

package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// RoleDefaultsFile is the basename of the role-defaults store under the state root.
const RoleDefaultsFile = "role-defaults.json"

// RoleDefault is a persisted default model and reasoning effort for one
// agent+role pair, and when it last changed.
type RoleDefault struct {
	Model           string `json:"model"`
	ReasoningEffort string `json:"reasoning_effort"`
	UpdatedAt       string `json:"updated_at"`
}

func (d RoleDefault) isEmpty() bool {
	return strings.TrimSpace(d.Model) == "" && strings.TrimSpace(d.ReasoningEffort) == ""
}

// RoleDefaultsStore persists per-agent, per-role default model and reasoning
// effort overrides in a single JSON file under the state root, so a
// configured default survives a restart. It mirrors RepoColorStore's
// atomic-write + flock discipline so concurrent writers cannot clobber each
// other. It is deliberately agnostic of what "agent" and "role" strings mean
// — validating those is the caller's job.
type RoleDefaultsStore struct {
	path string
}

// NewRoleDefaultsStore returns a store backed by <root>/role-defaults.json.
func NewRoleDefaultsStore(root string) *RoleDefaultsStore {
	return &RoleDefaultsStore{path: filepath.Join(root, RoleDefaultsFile)}
}

// Load reads every persisted role default. A missing file is not an error —
// it returns an empty map so callers degrade to "no defaults configured".
func (s *RoleDefaultsStore) Load() (map[string]RoleDefault, error) {
	return s.loadFrom()
}

func (s *RoleDefaultsStore) loadFrom() (map[string]RoleDefault, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]RoleDefault{}, nil
		}
		return nil, fmt.Errorf("read role defaults: %w", err)
	}
	var m map[string]RoleDefault
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse role defaults: %w", err)
	}
	if m == nil {
		m = map[string]RoleDefault{}
	}
	return m, nil
}

// Get returns the persisted default for agent+role and whether one is set.
func (s *RoleDefaultsStore) Get(agent, role string) (RoleDefault, bool, error) {
	m, err := s.Load()
	if err != nil {
		return RoleDefault{}, false, err
	}
	d, ok := m[roleDefaultsKey(agent, role)]
	return d, ok, nil
}

// Set records agent+role's default, stamping the change time. A def with
// both fields empty clears the override so launches fall back to the
// harness's own default. An empty agent or role is a no-op.
func (s *RoleDefaultsStore) Set(agent, role string, def RoleDefault) error {
	agent = strings.TrimSpace(agent)
	role = strings.TrimSpace(role)
	if agent == "" || role == "" {
		return nil
	}
	return s.withLock(func() error {
		m, err := s.loadFrom()
		if err != nil {
			if !isRoleDefaultsCorruptError(err) {
				return err
			}
			m = map[string]RoleDefault{}
		}
		key := roleDefaultsKey(agent, role)
		if def.isEmpty() {
			delete(m, key)
		} else {
			def.Model = strings.TrimSpace(def.Model)
			def.ReasoningEffort = strings.TrimSpace(def.ReasoningEffort)
			def.UpdatedAt = NowColorStamp()
			m[key] = def
		}
		return s.writeLocked(m)
	})
}

func roleDefaultsKey(agent, role string) string {
	return agent + ":" + role
}

func (s *RoleDefaultsStore) writeLocked(m map[string]RoleDefault) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal role defaults: %w", err)
	}
	data = append(data, '\n')

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write temp role defaults: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("rename role defaults: %w", err)
	}
	return nil
}

// withLock runs fn while holding an exclusive flock on a sibling lock file,
// creating the state root on first write.
func (s *RoleDefaultsStore) withLock(fn func() error) error {
	if err := EnsurePrivateStateRoot(filepath.Dir(s.path)); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	f, err := os.OpenFile(s.path+".lock", os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open role defaults lock: %w", err)
	}
	defer f.Close()

	if err := acquireFlock(f); err != nil {
		return fmt.Errorf("acquire role defaults lock: %w", err)
	}
	defer releaseFlock(f)

	return fn()
}

func isRoleDefaultsCorruptError(err error) bool {
	var syntaxErr *json.SyntaxError
	var typeErr *json.UnmarshalTypeError
	return errors.As(err, &syntaxErr) || errors.As(err, &typeErr)
}
