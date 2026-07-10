//go:build linux || darwin

package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type Quest struct {
	ID          string `json:"id"`
	Content     string `json:"content"`
	ProjectID   string `json:"project_id,omitempty"`
	ProjectPath string `json:"project_path,omitempty"`
	ProjectName string `json:"project_name,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
	SessionID   string `json:"session_id,omitempty"`
}

type questRegistry struct {
	Quests []Quest `json:"quests,omitempty"`
}

func QuestsRegistryPath(root string) string {
	return filepath.Join(root, "quests.json")
}

func QuestsRegistryLockPath(root string) string {
	return filepath.Join(root, "quests.json.lock")
}

func LoadQuests() ([]Quest, error) {
	return LoadQuestsAt(StateRoot())
}

func LoadQuestsAt(root string) ([]Quest, error) {
	if root == "" {
		return nil, nil
	}
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var quests []Quest
	err := withQuestsRegistryLock(root, func() error {
		var err error
		quests, err = loadQuestsLocked(root)
		return err
	})
	return quests, err
}

func UpsertQuestAt(root string, quest Quest) (Quest, error) {
	if root == "" {
		return Quest{}, errors.New("no state root resolved")
	}
	quest.Content = strings.TrimSpace(quest.Content)
	if quest.Content == "" {
		return Quest{}, errors.New("quest content is required")
	}
	if quest.SessionID != "" && !IsValidSessionID(quest.SessionID) {
		return Quest{}, fmt.Errorf("invalid session id: %q", quest.SessionID)
	}

	var saved Quest
	err := withQuestsRegistryLock(root, func() error {
		quests, err := loadQuestsLocked(root)
		if err != nil {
			return err
		}
		now := time.Now().UTC().Format(time.RFC3339Nano)
		if quest.ID == "" {
			quest.ID = nextQuestID(quests, time.Now())
		}
		quest = normalizeQuest(quest)
		for i := range quests {
			if quests[i].ID == quest.ID {
				if quest.CreatedAt == "" {
					quest.CreatedAt = quests[i].CreatedAt
				}
				quest.UpdatedAt = now
				saved = quest
				quests[i] = quest
				return writeQuestsLocked(root, quests)
			}
		}
		if quest.CreatedAt == "" {
			quest.CreatedAt = now
		}
		if quest.UpdatedAt == "" {
			quest.UpdatedAt = now
		}
		saved = quest
		return writeQuestsLocked(root, append(quests, quest))
	})
	return saved, err
}

func RemoveQuestAt(root, id string) (bool, error) {
	id = strings.TrimSpace(id)
	if id == "" {
		return false, errors.New("quest id is required")
	}
	if root == "" {
		return false, errors.New("no state root resolved")
	}
	removed := false
	err := withQuestsRegistryLock(root, func() error {
		quests, err := loadQuestsLocked(root)
		if err != nil {
			return err
		}
		next := make([]Quest, 0, len(quests))
		for _, quest := range quests {
			if quest.ID == id {
				removed = true
				continue
			}
			next = append(next, quest)
		}
		if !removed {
			return nil
		}
		return writeQuestsLocked(root, next)
	})
	return removed, err
}

func SortedQuests(quests []Quest) []Quest {
	if len(quests) == 0 {
		return nil
	}
	out := make([]Quest, 0, len(quests))
	for _, quest := range quests {
		quest = normalizeQuest(quest)
		if quest.ID == "" || quest.Content == "" {
			continue
		}
		out = append(out, quest)
	}
	sort.SliceStable(out, func(i, j int) bool {
		left, leftOK := parseQuestTime(out[i].UpdatedAt)
		right, rightOK := parseQuestTime(out[j].UpdatedAt)
		if leftOK && rightOK && !left.Equal(right) {
			return left.After(right)
		}
		if out[i].UpdatedAt != out[j].UpdatedAt {
			return out[i].UpdatedAt > out[j].UpdatedAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func loadQuestsLocked(root string) ([]Quest, error) {
	data, err := os.ReadFile(QuestsRegistryPath(root))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var payload questRegistry
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, fmt.Errorf("decode quests registry: %w", err)
	}
	return SortedQuests(payload.Quests), nil
}

func writeQuestsLocked(root string, quests []Quest) error {
	data, err := json.Marshal(questRegistry{Quests: SortedQuests(quests)})
	if err != nil {
		return fmt.Errorf("marshal quests registry: %w", err)
	}
	data = append(data, '\n')
	path := QuestsRegistryPath(root)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp quests registry: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename quests registry: %w", err)
	}
	return nil
}

func withQuestsRegistryLock(root string, fn func() error) error {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	return withFileLock(QuestsRegistryLockPath(root), fn)
}

func nextQuestID(quests []Quest, now time.Time) string {
	if now.IsZero() {
		now = time.Now()
	}
	base := fmt.Sprintf("qst-%d", now.Unix())
	used := make(map[string]struct{}, len(quests))
	for _, quest := range quests {
		used[quest.ID] = struct{}{}
	}
	if _, ok := used[base]; !ok {
		return base
	}
	for i := 2; ; i++ {
		id := fmt.Sprintf("%s-%d", base, i)
		if _, ok := used[id]; !ok {
			return id
		}
	}
}

func normalizeQuest(quest Quest) Quest {
	quest.ID = strings.TrimSpace(quest.ID)
	quest.Content = strings.TrimSpace(quest.Content)
	quest.ProjectID = strings.TrimSpace(quest.ProjectID)
	quest.ProjectPath = strings.TrimSpace(quest.ProjectPath)
	if quest.ProjectPath != "" {
		quest.ProjectPath = filepath.Clean(quest.ProjectPath)
	}
	quest.ProjectName = strings.TrimSpace(quest.ProjectName)
	quest.SessionID = strings.TrimSpace(quest.SessionID)
	return quest
}

func parseQuestTime(raw string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339Nano, raw)
	return t, err == nil
}
