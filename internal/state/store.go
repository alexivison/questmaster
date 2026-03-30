//go:build linux || darwin

// Package state provides manifest CRUD, locking, and session discovery.
package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"syscall"
	"time"
)

// Sentinel errors for manifest operations.
var (
	// ErrManifestExists is returned when Create finds an existing manifest.
	ErrManifestExists = errors.New("manifest already exists")
	// ErrManifestNotFound is returned when Delete targets a missing manifest.
	ErrManifestNotFound = errors.New("manifest not found")
)

var validPartyID = regexp.MustCompile(`^party-[a-zA-Z0-9_-]+$`)

// IsValidPartyID reports whether the given string is a valid party session ID.
func IsValidPartyID(id string) bool {
	return validPartyID.MatchString(id)
}

const defaultLockTimeout = 10 * time.Second

// Store manages manifest files on disk with flock-based locking.
type Store struct {
	root        string
	lockTimeout time.Duration
}

// NewStore creates a Store rooted at the given directory, creating it if needed.
func NewStore(root string) (*Store, error) {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return nil, fmt.Errorf("create state root: %w", err)
	}
	return &Store{root: root, lockTimeout: defaultLockTimeout}, nil
}

// OpenStore opens a Store for read-only access without creating the directory.
// DiscoverSessions and other reads gracefully return empty results if the directory
// does not exist. Use NewStore for mutating operations that need the directory.
func OpenStore(root string) *Store {
	return &Store{root: root, lockTimeout: defaultLockTimeout}
}

// Root returns the state directory path.
func (s *Store) Root() string { return s.root }

func (s *Store) validateID(partyID string) error {
	if !validPartyID.MatchString(partyID) {
		return fmt.Errorf("invalid party ID: %q", partyID)
	}
	return nil
}

func (s *Store) manifestPath(partyID string) string {
	return filepath.Join(s.root, partyID+".json")
}

func (s *Store) lockPath(partyID string) string {
	return filepath.Join(s.root, partyID+".json.lock")
}

// Create writes a new manifest. Returns an error if it already exists.
// Uses flock to prevent TOCTOU races between concurrent Create calls.
func (s *Store) Create(m Manifest) error {
	if err := s.validateID(m.PartyID); err != nil {
		return err
	}
	return s.withLock(m.PartyID, func() error {
		path := s.manifestPath(m.PartyID)
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			if err == nil {
				return fmt.Errorf("%w: %s", ErrManifestExists, m.PartyID)
			}
			return fmt.Errorf("check manifest: %w", err)
		}
		return s.writeManifest(path, m)
	})
}

// Read loads a manifest by party ID.
func (s *Store) Read(partyID string) (Manifest, error) {
	if err := s.validateID(partyID); err != nil {
		return Manifest{}, err
	}
	return s.readManifest(s.manifestPath(partyID))
}

// Update applies a mutation function to an existing manifest under lock.
func (s *Store) Update(partyID string, fn func(*Manifest)) error {
	if err := s.validateID(partyID); err != nil {
		return err
	}
	return s.withLock(partyID, func() error {
		m, err := s.readManifest(s.manifestPath(partyID))
		if err != nil {
			return err
		}
		fn(&m)
		m.PartyID = partyID // preserve filename/content invariant
		return s.writeManifest(s.manifestPath(partyID), m)
	})
}

// Delete removes a manifest file and its lock file.
func (s *Store) Delete(partyID string) error {
	if err := s.validateID(partyID); err != nil {
		return err
	}
	err := s.withLock(partyID, func() error {
		path := s.manifestPath(partyID)
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				return fmt.Errorf("%w: %s", ErrManifestNotFound, partyID)
			}
			return fmt.Errorf("check manifest: %w", err)
		}
		return os.Remove(path)
	})
	if err != nil {
		return err
	}
	// Best-effort lock file cleanup after releasing the flock.
	os.Remove(s.lockPath(partyID)) //nolint:errcheck
	return nil
}

// AddWorker adds a worker ID to the manifest's workers list (deduplicated).
func (s *Store) AddWorker(partyID, workerID string) error {
	return s.Update(partyID, func(m *Manifest) {
		for _, w := range m.Workers {
			if w == workerID {
				return
			}
		}
		m.Workers = append(m.Workers, workerID)
	})
}

// RemoveWorker removes a worker ID from the manifest's workers list.
func (s *Store) RemoveWorker(partyID, workerID string) error {
	return s.Update(partyID, func(m *Manifest) {
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
func (s *Store) GetWorkers(partyID string) ([]string, error) {
	m, err := s.Read(partyID) // Read validates partyID
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
func (s *Store) withLock(partyID string, fn func() error) error {
	lockPath := s.lockPath(partyID)
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open lock file: %w", err)
	}
	defer f.Close()

	if err := acquireFlock(f, s.lockTimeout); err != nil {
		return fmt.Errorf("acquire lock for %s: %w", partyID, err)
	}
	defer releaseFlock(f)

	return fn()
}

// acquireFlock acquires an exclusive flock with timeout.
func acquireFlock(f *os.File, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("lock timeout after %s", timeout)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// releaseFlock releases the flock.
func releaseFlock(f *os.File) {
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
}
