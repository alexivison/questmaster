package workspace

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

const ItemsDirName = "items"

// Artifact is the workspace item's durable content reference. Exactly one of
// Path or Inline is set; qm never moves or copies path-backed artifacts.
type Artifact struct {
	Path   string `json:"path,omitempty"`
	Inline string `json:"inline,omitempty"`
}

// Item is one workspace item manifest under the qm state root.
type Item struct {
	ID        string   `json:"id"`
	Type      string   `json:"type"`
	Title     string   `json:"title"`
	CreatedAt string   `json:"created_at"`
	Artifact  Artifact `json:"artifact"`
}

// ListedItem is the serve/CLI read model with attachment usage derived from
// quest JSON rather than stored on the item.
type ListedItem struct {
	Item
	Loose           bool     `json:"loose"`
	AttachmentCount int      `json:"attachment_count"`
	QuestIDs        []string `json:"quest_ids,omitempty"`
}

type CreateInput struct {
	Type     string
	Title    string
	Artifact Artifact
}

type Store struct {
	root string
}

func NewStore(root string) *Store {
	return &Store{root: root}
}

func OpenStore(root string) *Store {
	return &Store{root: root}
}

func Dir(root string) string {
	return filepath.Join(root, ItemsDirName)
}

func (s *Store) Dir() string {
	return Dir(s.root)
}

func (s *Store) Path(id string) string {
	return filepath.Join(s.Dir(), id+".json")
}

func (s *Store) Create(input CreateInput) (Item, error) {
	if err := validateCreateInput(input); err != nil {
		return Item{}, err
	}
	for i := 0; i < 16; i++ {
		item := Item{
			ID:        newItemID(),
			Type:      strings.TrimSpace(input.Type),
			Title:     strings.TrimSpace(input.Title),
			CreatedAt: state.NowUTC(),
			Artifact:  cleanArtifact(input.Artifact),
		}
		if err := s.writeNew(item); err != nil {
			if os.IsExist(err) {
				continue
			}
			return Item{}, err
		}
		return item, nil
	}
	return Item{}, fmt.Errorf("create workspace item: id collision")
}

func (s *Store) Get(id string) (Item, error) {
	if err := safeID(id); err != nil {
		return Item{}, err
	}
	return readItem(s.Path(id))
}

func (s *Store) List() ([]Item, error) {
	entries, err := os.ReadDir(s.Dir())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list workspace items: %w", err)
	}
	items := make([]Item, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") || ignoredItemFile(entry.Name()) {
			continue
		}
		item, err := readItem(filepath.Join(s.Dir(), entry.Name()))
		if err != nil {
			continue
		}
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ID < items[j].ID })
	return items, nil
}

func WithAttachmentUsage(items []Item, quests []quest.Quest) []ListedItem {
	type usage struct {
		count    int
		questIDs []string
		seen     map[string]struct{}
	}
	byItem := map[string]*usage{}
	for _, q := range quests {
		for _, ref := range q.Attachments {
			if ref.ItemID == "" {
				continue
			}
			u := byItem[ref.ItemID]
			if u == nil {
				u = &usage{seen: map[string]struct{}{}}
				byItem[ref.ItemID] = u
			}
			u.count++
			if q.ID != "" {
				if _, ok := u.seen[q.ID]; !ok {
					u.seen[q.ID] = struct{}{}
					u.questIDs = append(u.questIDs, q.ID)
				}
			}
		}
	}
	out := make([]ListedItem, len(items))
	for i, item := range items {
		u := byItem[item.ID]
		listed := ListedItem{Item: item, Loose: true}
		if u != nil {
			sort.Strings(u.questIDs)
			listed.Loose = u.count == 0
			listed.AttachmentCount = u.count
			listed.QuestIDs = u.questIDs
		}
		out[i] = listed
	}
	return out
}

func InferType(path, explicit string) string {
	if t := strings.TrimSpace(explicit); t != "" {
		return t
	}
	ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(path)), ".")
	switch ext {
	case "html", "htm":
		return "html"
	case "md", "markdown":
		return "markdown"
	case "txt", "text":
		return "text"
	case "json":
		return "json"
	case "":
		if looksLikeHTML(path) {
			return "html"
		}
		return "unknown"
	default:
		return ext
	}
}

func validateCreateInput(input CreateInput) error {
	if strings.TrimSpace(input.Type) == "" {
		return fmt.Errorf("workspace item type is required")
	}
	if strings.TrimSpace(input.Title) == "" {
		return fmt.Errorf("workspace item title is required")
	}
	artifact := cleanArtifact(input.Artifact)
	switch {
	case artifact.Path != "" && artifact.Inline != "":
		return fmt.Errorf("workspace item accepts only one of path or inline artifact")
	case artifact.Path == "" && artifact.Inline == "":
		return fmt.Errorf("workspace item artifact is required")
	default:
		return nil
	}
}

func cleanArtifact(artifact Artifact) Artifact {
	return Artifact{
		Path:   strings.TrimSpace(artifact.Path),
		Inline: artifact.Inline,
	}
}

func (s *Store) writeNew(item Item) error {
	if err := safeID(item.ID); err != nil {
		return err
	}
	if err := os.MkdirAll(s.Dir(), 0o755); err != nil {
		return fmt.Errorf("create workspace items dir: %w", err)
	}
	path := s.Path(item.ID)
	if _, err := os.Stat(path); err != nil {
		if !os.IsNotExist(err) {
			return fmt.Errorf("check workspace item: %w", err)
		}
	} else {
		return os.ErrExist
	}
	return writeItem(path, item)
}

func readItem(path string) (Item, error) {
	var item Item
	raw, err := os.ReadFile(path)
	if err != nil {
		return item, fmt.Errorf("read workspace item: %w", err)
	}
	if err := json.Unmarshal(raw, &item); err != nil {
		return item, fmt.Errorf("parse workspace item: %w", err)
	}
	return item, nil
}

func writeItem(path string, item Item) error {
	raw, err := json.MarshalIndent(item, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal workspace item: %w", err)
	}
	raw = append(raw, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return fmt.Errorf("write temp workspace item: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("commit workspace item: %w", err)
	}
	return nil
}

func newItemID() string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		binary.BigEndian.PutUint32(b[:], uint32(time.Now().UnixNano()))
	}
	return fmt.Sprintf("item-%d-%08x", time.Now().UTC().UnixNano(), binary.BigEndian.Uint32(b[:]))
}

func safeID(id string) error {
	if id == "" {
		return fmt.Errorf("workspace item id is required")
	}
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") || filepath.Base(id) != id {
		return fmt.Errorf("unsafe workspace item id %q: must be a single path component", id)
	}
	return nil
}

func ignoredItemFile(base string) bool {
	return strings.HasPrefix(base, ".") ||
		strings.HasSuffix(base, ".tmp") ||
		strings.HasSuffix(base, ".lock")
}

func looksLikeHTML(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close() //nolint:errcheck
	buf := make([]byte, 512)
	n, _ := f.Read(buf)
	s := strings.TrimSpace(strings.ToLower(string(buf[:n])))
	return strings.HasPrefix(s, "<!doctype html") || strings.HasPrefix(s, "<html") || strings.Contains(s, "<body")
}
