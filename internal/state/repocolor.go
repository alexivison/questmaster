//go:build linux || darwin

package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// RepoColorsFile is the basename of the repo-color store under the state root.
const RepoColorsFile = "repo-colors.json"

// RepoColor is a repository's persisted display color and when it last
// changed. UpdatedAt (RFC3339Nano, UTC) drives last-write-wins resolution
// against a session's own color.
type RepoColor struct {
	Color     string `json:"color"`
	UpdatedAt string `json:"updated_at"`
}

// RepoColorStore persists per-repository colors keyed by repo identity (the
// resolved common git dir) in a single JSON file under the state root, so a
// repo color survives a tracker restart. It mirrors the manifest store's
// atomic-write + flock discipline so concurrent tracker panes cannot clobber
// each other.
type RepoColorStore struct {
	path string
}

// NewRepoColorStore returns a store backed by <root>/repo-colors.json.
func NewRepoColorStore(root string) *RepoColorStore {
	return &RepoColorStore{path: filepath.Join(root, RepoColorsFile)}
}

// Load reads every repo color. A missing file is not an error — it returns an
// empty map so the tracker degrades to "no repo colors set".
func (s *RepoColorStore) Load() (map[string]RepoColor, error) {
	return s.loadFrom()
}

func (s *RepoColorStore) loadFrom() (map[string]RepoColor, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]RepoColor{}, nil
		}
		return nil, fmt.Errorf("read repo colors: %w", err)
	}
	var m map[string]RepoColor
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse repo colors: %w", err)
	}
	if m == nil {
		m = map[string]RepoColor{}
	}
	return m, nil
}

// Get returns a repo's color and whether one is set.
func (s *RepoColorStore) Get(identity string) (RepoColor, bool, error) {
	m, err := s.Load()
	if err != nil {
		return RepoColor{}, false, err
	}
	rc, ok := m[identity]
	return rc, ok, nil
}

// Set records a repo's color, stamping the change time. An empty color clears
// the override so sessions fall back to their own explicit color or the
// default. An empty identity is a no-op (a path outside any repo cannot carry
// a repo color).
func (s *RepoColorStore) Set(identity, color string) error {
	identity = strings.TrimSpace(identity)
	if identity == "" {
		return nil
	}
	return s.withLock(func() error {
		m, err := s.loadFrom()
		if err != nil {
			return err
		}
		if strings.TrimSpace(color) == "" {
			delete(m, identity)
		} else {
			m[identity] = RepoColor{Color: NormalizeDisplayColor(color), UpdatedAt: NowColorStamp()}
		}
		return s.writeLocked(m)
	})
}

func (s *RepoColorStore) writeLocked(m map[string]RepoColor) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal repo colors: %w", err)
	}
	data = append(data, '\n')

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write temp repo colors: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("rename repo colors: %w", err)
	}
	return nil
}

// withLock runs fn while holding an exclusive flock on a sibling lock file,
// creating the state root on first write.
func (s *RepoColorStore) withLock(fn func() error) error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	f, err := os.OpenFile(s.path+".lock", os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open repo colors lock: %w", err)
	}
	defer f.Close()

	if err := acquireFlock(f); err != nil {
		return fmt.Errorf("acquire repo colors lock: %w", err)
	}
	defer releaseFlock(f)

	return fn()
}

// NowColorStamp returns the current time as an RFC3339Nano UTC string. Both a
// session color and a repo color stamp their change time with it; the
// nanosecond precision keeps two near-simultaneous recolors from tying.
func NowColorStamp() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}

// ParseColorStamp parses a color change timestamp, returning the zero time for
// an empty or malformed value (which then loses last-write-wins ties).
func ParseColorStamp(s string) time.Time {
	if strings.TrimSpace(s) == "" {
		return time.Time{}
	}
	t, err := time.Parse(time.RFC3339Nano, s)
	if err != nil {
		return time.Time{}
	}
	return t
}

// EffectiveColor resolves the last-write-wins color for a session: between its
// own color (changed at ownAt) and its repo color (changed at repoAt),
// whichever changed most recently wins. An empty color means unset; "" is
// returned when neither is set so the caller applies the default. The repo
// wins only when strictly newer, so a same-instant tie keeps the session's own
// color.
func EffectiveColor(ownColor string, ownAt time.Time, repoColor string, repoAt time.Time) string {
	hasOwn := strings.TrimSpace(ownColor) != ""
	hasRepo := strings.TrimSpace(repoColor) != ""
	switch {
	case hasOwn && hasRepo:
		if repoAt.After(ownAt) {
			return repoColor
		}
		return ownColor
	case hasOwn:
		return ownColor
	case hasRepo:
		return repoColor
	default:
		return ""
	}
}
