package quest

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Store is the quest file store. Quests live in the dotfile home
// (<Home>/quests/<id>.html), never in a repo.
type Store interface {
	Load(id string) (*Document, error)
	Save(d *Document) error // re-validates Head against the schema before writing
	List() ([]Quest, error) // heads only
	Path(id string) string
}

// FileStore is the on-disk Store rooted at a quests directory (typically
// paths.Paths.QuestsDir(), under the Quests home — never a repo path).
type FileStore struct {
	dir string
}

var _ Store = (*FileStore)(nil)

// NewStore returns a FileStore rooted at dir. The directory is created lazily
// on Save.
func NewStore(dir string) *FileStore {
	return &FileStore{dir: dir}
}

// Dir returns the store's root directory.
func (s *FileStore) Dir() string { return s.dir }

// Path returns the absolute file path for a quest id, always under the store
// directory. An id that is not a safe single path component yields a path that
// Save/Load will reject.
func (s *FileStore) Path(id string) string {
	return filepath.Join(s.dir, id+".html")
}

// Load reads and parses a quest file. It does not re-validate the schema (the
// write path is the gate); callers wanting integrity should Validate the head.
func (s *FileStore) Load(id string) (*Document, error) {
	if err := safeID(id); err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(s.Path(id))
	if err != nil {
		return nil, fmt.Errorf("load quest %q: %w", id, err)
	}
	return Parse(raw)
}

// Save validates the document's head and, only if it conforms, writes the raw
// body to <dir>/<id>.html atomically. A malformed head is refused and the
// validation error returned, to be fed back to the author (refuse-and-re-engage).
func (s *FileStore) Save(d *Document) error {
	if d == nil {
		return fmt.Errorf("save quest: nil document")
	}
	if err := Validate(d.Head); err != nil {
		return err
	}
	id := d.Head.ID
	if err := safeID(id); err != nil {
		return err
	}
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return fmt.Errorf("create quest store dir: %w", err)
	}
	path := s.Path(id)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, d.Body, 0o644); err != nil {
		return fmt.Errorf("write quest %q: %w", id, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit quest %q: %w", id, err)
	}
	return nil
}

// List returns the heads of every parseable quest in the store, sorted by id.
// Files that fail to parse are skipped so one malformed quest never blanks the
// cockpit list.
func (s *FileStore) List() ([]Quest, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list quests: %w", err)
	}
	var heads []Quest
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".html") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(s.dir, e.Name()))
		if err != nil {
			continue
		}
		doc, err := Parse(raw)
		if err != nil {
			continue
		}
		heads = append(heads, doc.Head)
	}
	sort.Slice(heads, func(i, j int) bool { return heads[i].ID < heads[j].ID })
	return heads, nil
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
