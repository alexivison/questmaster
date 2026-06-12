package gate

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// QuestResults is the latest auto-gate results for one quest, keyed by gate
// name. It is observed, transient runtime state — it lives in the sidecar,
// never in the quest JSON.
type QuestResults struct {
	QuestID string            `json:"quest_id"`
	Gates   map[string]Result `json:"gates"`
}

// StatusMap projects the results to gate-name → status string, the shape the
// renderer overlays onto the detail pane (pass/fail/error).
func (q QuestResults) StatusMap() map[string]string {
	if len(q.Gates) == 0 {
		return nil
	}
	m := make(map[string]string, len(q.Gates))
	for name, r := range q.Gates {
		m[name] = string(r.Status)
	}
	return m
}

// RanAtMap projects the results to gate-name → observation time, so renderers
// can show how fresh each verdict is. Zero times (legacy sidecar files) are
// omitted.
func (q QuestResults) RanAtMap() map[string]time.Time {
	if len(q.Gates) == 0 {
		return nil
	}
	m := make(map[string]time.Time, len(q.Gates))
	for name, r := range q.Gates {
		if !r.RanAt.IsZero() {
			m[name] = r.RanAt
		}
	}
	if len(m) == 0 {
		return nil
	}
	return m
}

// Sidecar is the runtime store of auto-gate results, one JSON file per quest at
// <dir>/<id>.json. dir is under qm's dotfiles (a sibling of the quest store),
// never a repo. The quest JSON is never touched by a check run.
type Sidecar struct {
	dir string
}

// NewSidecar returns a sidecar rooted at dir (created lazily on Save).
func NewSidecar(dir string) *Sidecar { return &Sidecar{dir: dir} }

// Dir returns the sidecar's root directory.
func (s *Sidecar) Dir() string { return s.dir }

func (s *Sidecar) path(questID string) string {
	return filepath.Join(s.dir, questID+".json")
}

// Save writes the latest results for a quest atomically (tmp + rename).
func (s *Sidecar) Save(questID string, results []Result) error {
	if err := safeID(questID); err != nil {
		return err
	}
	qr := QuestResults{QuestID: questID, Gates: make(map[string]Result, len(results))}
	for _, r := range results {
		qr.Gates[r.Gate] = r
	}
	data, err := json.MarshalIndent(qr, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal results: %w", err)
	}
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return fmt.Errorf("create sidecar dir: %w", err)
	}
	path := s.path(questID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write results %q: %w", questID, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("commit results %q: %w", questID, err)
	}
	return nil
}

// Load reads a quest's results, returning empty (not an error) when none have
// been recorded yet.
func (s *Sidecar) Load(questID string) (QuestResults, error) {
	if err := safeID(questID); err != nil {
		return QuestResults{}, err
	}
	data, err := os.ReadFile(s.path(questID))
	if err != nil {
		if os.IsNotExist(err) {
			return QuestResults{QuestID: questID}, nil
		}
		return QuestResults{}, fmt.Errorf("load results %q: %w", questID, err)
	}
	var qr QuestResults
	if err := json.Unmarshal(data, &qr); err != nil {
		return QuestResults{}, fmt.Errorf("decode results %q: %w", questID, err)
	}
	return qr, nil
}

// safeID rejects ids that are not a single safe path component, so a result
// file can never be written outside the sidecar directory.
func safeID(id string) error {
	if id == "" {
		return fmt.Errorf("quest id is required")
	}
	if strings.ContainsAny(id, `/\`) || strings.Contains(id, "..") || filepath.Base(id) != id {
		return fmt.Errorf("unsafe quest id %q", id)
	}
	return nil
}
