//go:build linux || darwin

// Package state provides manifest CRUD, locking, and session discovery.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Sentinel errors for manifest operations.
var (
	// ErrManifestExists is returned when Create finds an existing manifest.
	ErrManifestExists = errors.New("manifest already exists")
	// ErrManifestNotFound is returned when Delete targets a missing manifest.
	ErrManifestNotFound = errors.New("manifest not found")
)

// Store manages manifest files on disk with flock-based locking.
type Store struct {
	root string
}

// EnsurePrivateStateRoot creates root if needed and tightens existing roots to
// owner-only access. The state root holds prompts, cwd metadata, and sockets.
func EnsurePrivateStateRoot(root string) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return err
	}
	return nil
}

// NewStore creates a Store rooted at the given directory, creating it if needed.
func NewStore(root string) (*Store, error) {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return nil, fmt.Errorf("create state root: %w", err)
	}
	return &Store{root: root}, nil
}

// OpenStore opens a Store for read-only access without creating the directory.
// DiscoverSessions and other reads gracefully return empty results if the directory
// does not exist. Use NewStore for mutating operations that need the directory.
func OpenStore(root string) *Store {
	return &Store{root: root}
}

// Root returns the state directory path.
func (s *Store) Root() string { return s.root }

func (s *Store) validateID(sessionID string) error {
	if !IsValidSessionID(sessionID) {
		return fmt.Errorf("invalid session ID %q (expected qm-*)", sessionID)
	}
	return nil
}

func (s *Store) manifestPath(sessionID string) string {
	return filepath.Join(s.root, sessionID+".json")
}

func (s *Store) lockPath(sessionID string) string {
	return filepath.Join(s.root, sessionID+".json.lock")
}

// Create writes a new manifest. Returns an error if it already exists.
// Uses flock to prevent TOCTOU races between concurrent Create calls.
func (s *Store) Create(m Manifest) error {
	if err := s.validateID(m.SessionID); err != nil {
		return err
	}
	return s.withLock(m.SessionID, func() error {
		path := s.manifestPath(m.SessionID)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			if err == nil {
				return fmt.Errorf("%w: %s", ErrManifestExists, m.SessionID)
			}
			return fmt.Errorf("check manifest: %w", err)
		}
		return s.writeManifest(path, m)
	})
}

// Read loads a manifest by session ID.
func (s *Store) Read(sessionID string) (Manifest, error) {
	if err := s.validateID(sessionID); err != nil {
		return Manifest{}, err
	}
	return s.readManifest(s.manifestPath(sessionID))
}

// Update applies a mutation function to an existing manifest under lock.
func (s *Store) Update(sessionID string, fn func(*Manifest)) error {
	if err := s.validateID(sessionID); err != nil {
		return err
	}
	return s.withLock(sessionID, func() error {
		m, err := s.readManifest(s.manifestPath(sessionID))
		if err != nil {
			return err
		}
		fn(&m)
		m.SessionID = sessionID // preserve filename/content invariant
		return s.writeManifest(s.manifestPath(sessionID), m)
	})
}

// Delete removes a manifest file and its lock file.
func (s *Store) Delete(sessionID string) error {
	if err := s.validateID(sessionID); err != nil {
		return err
	}
	err := s.withLock(sessionID, func() error {
		path := s.manifestPath(sessionID)
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf("%w: %s", ErrManifestNotFound, sessionID)
			}
			return fmt.Errorf("check manifest: %w", err)
		}
		return os.Remove(path)
	})
	if err != nil {
		return err
	}
	// Best-effort lock file cleanup after releasing the flock.
	os.Remove(s.lockPath(sessionID)) //nolint:errcheck
	return nil
}

// AddWorker adds a worker ID to the manifest's workers list (deduplicated).
func (s *Store) AddWorker(sessionID, workerID string) error {
	return s.Update(sessionID, func(m *Manifest) {
		for _, w := range m.Workers {
			if w == workerID {
				return
			}
		}
		m.Workers = append(m.Workers, workerID)
	})
}

// RemoveWorker removes a worker ID from the manifest's workers list.
func (s *Store) RemoveWorker(sessionID, workerID string) error {
	return s.Update(sessionID, func(m *Manifest) {
		filtered := make([]string, 0, len(m.Workers))
		for _, w := range m.Workers {
			if w != workerID {
				filtered = append(filtered, w)
			}
		}
		m.Workers = filtered
	})
}

// GetWorkers returns the worker IDs from a manifest.
func (s *Store) GetWorkers(sessionID string) ([]string, error) {
	m, err := s.Read(sessionID) // Read validates the session ID.
	if err != nil {
		return nil, err
	}
	return m.Workers, nil
}

// readManifest reads and parses a manifest file.
func (s *Store) readManifest(path string) (Manifest, error) {
	var m Manifest
	data, err := os.ReadFile(path)
	if err != nil {
		return m, fmt.Errorf("read manifest: %w", err)
	}
	if err := json.Unmarshal(data, &m); err != nil {
		return m, fmt.Errorf("parse manifest: %w", err)
	}
	return m, nil
}

// writeManifest atomically writes a manifest to disk.
// Mirrors bash semantics: initializes created_at on first write, bumps updated_at always.
func (s *Store) writeManifest(path string, m Manifest) error {
	now := NowUTC()
	if m.CreatedAt == "" {
		m.CreatedAt = now
	}
	m.UpdatedAt = now

	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal manifest: %w", err)
	}
	data = append(data, '\n')

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write temp manifest: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename manifest: %w", err)
	}
	return nil
}

// withLock executes fn while holding an flock on the manifest's lock file.
// MkdirAll the state root so mutating ops succeed on a fresh install where
// only OpenStore (read-only safe) was used to construct the Store.
func (s *Store) withLock(sessionID string, fn func() error) error {
	if err := EnsurePrivateStateRoot(s.root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	lockPath := s.lockPath(sessionID)
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock file: %w", err)
	}
	defer f.Close()

	if err := acquireFlock(f); err != nil {
		return fmt.Errorf("acquire lock for %s: %w", sessionID, err)
	}
	defer releaseFlock(f)

	return fn()
}

// acquireFlock acquires an exclusive flock.
func acquireFlock(f *os.File) error {
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
}

// releaseFlock releases the flock.
func releaseFlock(f *os.File) {
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
}
