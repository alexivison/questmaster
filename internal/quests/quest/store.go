package quest

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
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

// Exists reports whether a quest file is present for id.
func (s *FileStore) Exists(id string) bool {
	if safeID(id) != nil {
		return false
	}
	_, err := os.Stat(s.Path(id))
	return err == nil
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
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
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
