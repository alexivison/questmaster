package quest

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// HomeEnv overrides the questmaster home directory (the parent of quests/).
// Defaults to ~/.questmaster. Authored quest docs live here, deliberately
// separate from the ephemeral session-state root (~/.questmaster-state).
const HomeEnv = "QUESTMASTER_HOME"

// Home resolves the questmaster home directory: $QUESTMASTER_HOME, else
// ~/.questmaster. Returns "" only when neither the override nor $HOME is set.
func Home() string {
	if h := os.Getenv(HomeEnv); h != "" {
		return h
	}
	if home := os.Getenv("HOME"); home != "" {
		return filepath.Join(home, ".questmaster")
	}
	return ""
}

// QuestsDir is <home>/quests, the store root. Quests are never written into a
// repo and never committed.
func QuestsDir() string {
	h := Home()
	if h == "" {
		return ""
	}
	return filepath.Join(h, "quests")
}

// FileStore is the on-disk quest store rooted at a quests directory (under the
// questmaster home — never a repo path). Files are self-contained, browser-
// openable HTML carrying the canonical JSON in a <script id="quest"> block.
type FileStore struct {
	dir string
}

// NewStore returns a FileStore rooted at dir. The directory is created lazily
// on Save.
func NewStore(dir string) *FileStore {
	return &FileStore{dir: dir}
}

// DefaultStore returns a FileStore rooted at the resolved QuestsDir.
func DefaultStore() *FileStore {
	return &FileStore{dir: QuestsDir()}
}

// Dir returns the store's root directory.
func (s *FileStore) Dir() string { return s.dir }

// Path returns the absolute file path for a quest id, always under the store
// directory. An id that is not a safe single path component yields a path that
// Load/Save reject.
func (s *FileStore) Path(id string) string {
	return filepath.Join(s.dir, id+".html")
}

func ensurePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(dir, 0o700)
}

func (s *FileStore) ensureDir() error {
	home := Home()
	if home != "" && isWithinDir(s.dir, home) {
		if err := ensurePrivateDir(home); err != nil {
			return err
		}
	}
	return ensurePrivateDir(s.dir)
}

func isWithinDir(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// Exists reports whether a quest file is present for id.
func (s *FileStore) Exists(id string) bool {
	if safeID(id) != nil {
		return false
	}
	_, err := os.Stat(s.Path(id))
	return err == nil
}

// Update applies a locked read-modify-write to one quest.
func (s *FileStore) Update(id string, mutate func(*Quest) error) (*Quest, error) {
	if mutate == nil {
		return nil, fmt.Errorf("update quest %q: nil mutate function", id)
	}
	if err := safeID(id); err != nil {
		return nil, err
	}
	if s.dir == "" {
		return nil, errors.New("quest store directory is not resolved")
	}
	var updated *Quest
	err := s.withLock(id, func() error {
		q, err := s.Load(id)
		if err != nil {
			return err
		}
		if err := mutate(q); err != nil {
			return err
		}
		if err := s.Save(q); err != nil {
			return err
		}
		updated = q
		return nil
	})
	if err != nil {
		return nil, err
	}
	return updated, nil
}

// Save validates the quest and, only if it conforms, rebuilds the HTML body
// from the canonical JSON (Build) and writes it to <dir>/<id>.html atomically
// (tmp + rename). A malformed quest is refused and the validation error
// returned, to be fed back to the author (refuse-and-re-engage). Quests are
// never written into a repo and never committed.
func (s *FileStore) Save(q *Quest) error {
	if q == nil {
		return fmt.Errorf("save quest: nil quest")
	}
	q = canonicalQuest(q)
	if err := Validate(q); err != nil {
		return err
	}
	if err := safeID(q.ID); err != nil {
		return err
	}
	body, err := Build(q)
	if err != nil {
		return err
	}
	if err := s.ensureDir(); err != nil {
		return fmt.Errorf("create quest store dir: %w", err)
	}
	path := s.Path(q.ID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, body, 0o644); err != nil {
		return fmt.Errorf("write quest %q: %w", q.ID, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit quest %q: %w", q.ID, err)
	}
	return nil
}

// Load reads and parses a quest file by id. It does not re-validate the schema
// (the write path is the gate); callers wanting integrity Validate the result.
func (s *FileStore) Load(id string) (*Quest, error) {
	if err := safeID(id); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(s.Path(id))
	if err != nil {
		return nil, fmt.Errorf("load quest %q: %w", id, err)
	}
	return Parse(raw)
}

// List returns every parseable quest in the store, sorted by id. Files that
// fail to parse are skipped so one malformed quest never blanks the board.
func (s *FileStore) List() ([]Quest, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list quests: %w", err)
	}
	var quests []Quest
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".html") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			continue
		}
		q, err := Parse(raw)
		if err != nil {
			continue
		}
		quests = append(quests, *q)
	}
	sort.Slice(quests, func(i, j int) bool { return quests[i].ID < quests[j].ID })
	return quests, nil
}

// Fingerprint returns a cheap signature of the store's current contents —
// each quest file's name, size, and modification time — WITHOUT reading or
// parsing any file. The board polls on a timer; comparing fingerprints lets it
// skip the parse-heavy List() (regexp + JSON per file) on ticks where nothing
// on disk changed. A changed fingerprint means "re-read"; an unchanged one is
// safe to treat as "no authored change since last poll".
func (s *FileStore) Fingerprint() (string, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("fingerprint quests: %w", err)
	}
	var b strings.Builder
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".html") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			// A transient stat error must not make two different states
			// fingerprint equal; emit a distinct token so we fall back to a read.
			fmt.Fprintf(&b, "%s:?\n", e.Name())
			continue
		}
		fmt.Fprintf(&b, "%s:%d:%d\n", e.Name(), info.Size(), info.ModTime().UnixNano())
	}
	return b.String(), nil
}

// Delete removes a quest file by id. The id must be a safe single path
// component (same guard as Load/Save). A missing quest is reported as
// not-found rather than surfacing the raw os error.
func (s *FileStore) Delete(id string) error {
	if err := safeID(id); err != nil {
		return err
	}
	if err := os.Remove(s.Path(id)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("quest %q not found", id)
		}
		return fmt.Errorf("delete quest %q: %w", id, err)
	}
	return nil
}

// safeID rejects ids that are empty or not a single safe path component, so a
// quest can never be written outside its store directory (e.g. into a repo via
// "../" traversal).
func safeID(id string) error {
	if id == "" {
		return fmt.Errorf("quest id is required")
	}
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") || filepath.Base(id) != id {
		return fmt.Errorf("unsafe quest id %q: must be a single path component", id)
	}
	return nil
}

func (s *FileStore) withLock(id string, fn func() error) error {
	if err := s.ensureDir(); err != nil {
		return fmt.Errorf("create quest store dir: %w", err)
	}
	lockPath := s.Path(id) + ".lock"
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open quest lock: %w", err)
	}
	defer f.Close() //nolint:errcheck
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire quest lock for %s: %w", id, err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return fn()
}
