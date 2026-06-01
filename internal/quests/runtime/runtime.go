// Package runtime is the harness-owned observed state of a quest: gate results,
// sessions, PR/CI, attempts. It is written by the harness and never authored —
// the quest file holds the authored content, this record holds what is
// observed. "One fact, one home": nothing here is duplicated in the quest file.
//
// In Stage 1 the harness populates Status, Sessions, and PR; GateResults and
// Attempts exist (for Stage 2) but stay empty.
package runtime

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Status is the lifecycle state of a quest.
type Status string

const (
	StatusDraft      Status = "draft"
	StatusReady      Status = "ready"
	StatusInProgress Status = "in_progress"
	StatusBlocked    Status = "blocked"
	StatusDone       Status = "done"
)

// SessionRef is a lightweight projection of a session from the questmaster
// state spine.
type SessionRef struct {
	ID    string `json:"id"`
	Role  string `json:"role"`  // solo | master | worker
	Agent string `json:"agent"` // claude | codex | pi
	State string `json:"state"` // working | blocked | done | idle | ...
}

// PRStatus is the observed PR/CI state (produced by the adapter, persisted
// here). CI: green|pending|failed|none. Review: approved|pending|changes|none.
type PRStatus struct {
	Number int    `json:"number"`
	URL    string `json:"url"`
	CI     string `json:"ci"`
	Review string `json:"review"`
}

// Attempt is one session tree's run under a quest (Stage 2+).
type Attempt struct {
	N       int       `json:"n"`
	Started time.Time `json:"started"`
	Outcome string    `json:"outcome"`
}

// RuntimeRecord is the observed state of a quest (build-spec §4).
type RuntimeRecord struct {
	QuestID     string            `json:"quest_id"`
	Status      Status            `json:"status"`
	GateResults map[string]string `json:"gate_results"` // gate name -> green|pending|failed|unset (Stage 2)
	Sessions    []SessionRef      `json:"sessions"`
	PR          *PRStatus         `json:"pr,omitempty"`
	Attempts    []Attempt         `json:"attempts"` // Stage 2+
	UpdatedAt   time.Time         `json:"updated_at"`
}

// Store reads and writes runtime records beside the quest, under the Quests
// home (never a repo). It is rooted at the same directory as the quest store
// (paths.Paths.QuestsDir()); the record for id lives at <dir>/<id>.runtime.json.
type Store struct {
	dir string
	now func() time.Time
}

// NewStore returns a runtime Store rooted at dir (the quests dir).
func NewStore(dir string) *Store {
	return &Store{dir: dir, now: func() time.Time { return time.Now().UTC() }}
}

// Path returns the runtime record file path for a quest id, beside its .html.
func (s *Store) Path(id string) string {
	return filepath.Join(s.dir, id+".runtime.json")
}

// Load reads the runtime record for a quest. If none exists yet, it returns a
// fresh draft record (so the cockpit can overlay a quest that has never run).
func (s *Store) Load(id string) (*RuntimeRecord, error) {
	data, err := os.ReadFile(s.Path(id))
	if err != nil {
		if os.IsNotExist(err) {
			return &RuntimeRecord{
				QuestID:     id,
				Status:      StatusDraft,
				GateResults: map[string]string{},
			}, nil
		}
		return nil, fmt.Errorf("load runtime %q: %w", id, err)
	}
	var rec RuntimeRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("parse runtime %q: %w", id, err)
	}
	if rec.GateResults == nil {
		rec.GateResults = map[string]string{}
	}
	return &rec, nil
}

// Save writes the runtime record atomically, stamping UpdatedAt.
func (s *Store) Save(rec *RuntimeRecord) error {
	if rec == nil {
		return fmt.Errorf("save runtime: nil record")
	}
	if rec.QuestID == "" {
		return fmt.Errorf("save runtime: quest id is required")
	}
	rec.UpdatedAt = s.now()
	if rec.GateResults == nil {
		rec.GateResults = map[string]string{}
	}
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return fmt.Errorf("create runtime dir: %w", err)
	}
	data, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal runtime: %w", err)
	}
	data = append(data, '\n')
	path := s.Path(rec.QuestID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write runtime: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit runtime: %w", err)
	}
	return nil
}
