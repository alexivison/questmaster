//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Manifest JSON serialization
// ---------------------------------------------------------------------------

func TestManifest_JSONRoundTrip(t *testing.T) {
	t.Parallel()

	m := Manifest{
		PartyID:    "party-abc",
		CreatedAt:  "2026-03-20T10:00:00Z",
		UpdatedAt:  "2026-03-20T11:00:00Z",
		Title:      "test session",
		Cwd:        "/tmp/work",
		WindowName: "main",
		Agents: []AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/local/bin/claude", ResumeID: "claude-1", Window: 1},
			{Name: "codex", Role: "companion", CLI: "/usr/local/bin/codex", ResumeID: "codex-1", Window: 0},
		},
		AgentPath: "/home/user/.claude",
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got Manifest
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if got.PartyID != m.PartyID || got.CreatedAt != m.CreatedAt ||
		got.UpdatedAt != m.UpdatedAt || got.Title != m.Title ||
		got.Cwd != m.Cwd || got.WindowName != m.WindowName ||
		!slices.Equal(got.Agents, m.Agents) ||
		got.AgentPath != m.AgentPath || got.SessionType != m.SessionType ||
		!slices.Equal(got.Workers, m.Workers) {
		t.Fatalf("round-trip mismatch:\n got: %+v\nwant: %+v", got, m)
	}
}

func TestManifest_JSONFieldNames(t *testing.T) {
	t.Parallel()

	m := Manifest{
		PartyID:     "party-x",
		SessionType: "master",
		Workers:     []string{"party-w1", "party-w2"},
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}

	wantKeys := []string{"party_id", "session_type", "workers"}
	for _, k := range wantKeys {
		if _, ok := raw[k]; !ok {
			t.Errorf("expected JSON key %q, not found in %v", k, raw)
		}
	}
}

func TestManifest_OlderManifestMissingOptionalFields(t *testing.T) {
	t.Parallel()

	older := `{"party_id":"party-old","created_at":"2026-01-01T00:00:00Z","cwd":"/old"}`

	var m Manifest
	if err := json.Unmarshal([]byte(older), &m); err != nil {
		t.Fatalf("unmarshal older manifest: %v", err)
	}

	if m.PartyID != "party-old" {
		t.Errorf("party_id: got %q, want %q", m.PartyID, "party-old")
	}
	if m.Cwd != "/old" {
		t.Errorf("cwd: got %q, want %q", m.Cwd, "/old")
	}
	if m.SessionType != "" {
		t.Errorf("session_type: got %q, want empty", m.SessionType)
	}
	if m.Workers != nil {
		t.Errorf("workers: got %v, want nil", m.Workers)
	}
	if len(m.Agents) != 0 {
		t.Errorf("agents: got %v, want nil", m.Agents)
	}
}

func TestManifest_ExtraFieldsPreserved(t *testing.T) {
	t.Parallel()

	// Manifest with unknown fields (from bash helpers)
	input := `{"party_id":"party-f","cwd":"/f","parent_session":"party-master","initial_prompt":"hello","claude_session_id":"abc123"}`

	var m Manifest
	if err := json.Unmarshal([]byte(input), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if m.PartyID != "party-f" {
		t.Errorf("party_id: got %q, want %q", m.PartyID, "party-f")
	}

	// Re-marshal and verify unknown fields survive
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}

	for _, key := range []string{"parent_session", "initial_prompt", "claude_session_id"} {
		if _, ok := raw[key]; !ok {
			t.Errorf("unknown field %q lost during round-trip", key)
		}
	}
}

// ---------------------------------------------------------------------------
// Store CRUD
// ---------------------------------------------------------------------------

func newTestStore(t *testing.T) *Store {
	t.Helper()
	dir := t.TempDir()
	s, err := NewStore(dir)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return s
}

func TestStore_CreateAndRead(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{
		PartyID:   "party-test",
		CreatedAt: "2026-03-20T10:00:00Z",
		UpdatedAt: "2026-03-20T10:00:00Z",
		Title:     "test",
		Cwd:       "/tmp",
	}

	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := s.Read("party-test")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	if got.PartyID != "party-test" {
		t.Errorf("PartyID: got %q, want %q", got.PartyID, "party-test")
	}
	if got.Title != "test" {
		t.Errorf("Title: got %q, want %q", got.Title, "test")
	}
}

func TestStore_CreateDuplicate(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-dup", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("first Create: %v", err)
	}

	err := s.Create(m)
	if err == nil {
		t.Fatal("expected error on duplicate Create, got nil")
	}
}

func TestStore_ReadNotFound(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	_, err := s.Read("party-nonexistent")
	if err == nil {
		t.Fatal("expected error on Read of nonexistent manifest, got nil")
	}
}

func TestStore_Update(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{
		PartyID: "party-upd",
		Title:   "original",
		Cwd:     "/tmp",
	}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Update("party-upd", func(m *Manifest) {
		m.Title = "updated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("party-upd")
	if err != nil {
		t.Fatalf("Read after update: %v", err)
	}
	if got.Title != "updated" {
		t.Errorf("Title: got %q, want %q", got.Title, "updated")
	}
}

func TestStore_UpdateNotFound(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	err := s.Update("party-ghost", func(m *Manifest) {
		m.Title = "nope"
	})
	if err == nil {
		t.Fatal("expected error on Update of nonexistent manifest, got nil")
	}
}

func TestStore_UpdatePreservesPartyID(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{PartyID: "party-inv", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Callback tries to mutate PartyID — should be overridden
	if err := s.Update("party-inv", func(m *Manifest) {
		m.PartyID = "party-other"
		m.Title = "mutated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("party-inv")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.PartyID != "party-inv" {
		t.Errorf("PartyID: got %q, want %q", got.PartyID, "party-inv")
	}
	if got.Title != "mutated" {
		t.Errorf("Title: got %q, want %q", got.Title, "mutated")
	}
}

func TestStore_UpdateViaField(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-sf", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Update("party-sf", func(m *Manifest) {
		m.SessionType = "master"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("party-sf")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.SessionType != "master" {
		t.Errorf("SessionType: got %q, want %q", got.SessionType, "master")
	}
}

func TestStore_Delete(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-del", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Delete("party-del"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	_, err := s.Read("party-del")
	if err == nil {
		t.Fatal("expected error after Delete, got nil")
	}
}

func TestStore_DeleteNotFound(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	err := s.Delete("party-nope")
	if err == nil {
		t.Fatal("expected error on Delete of nonexistent manifest, got nil")
	}
}

func TestStore_TimestampsAutoManaged(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	// Create without timestamps — they should be auto-set
	m := Manifest{PartyID: "party-ts", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := s.Read("party-ts")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.CreatedAt == "" {
		t.Error("CreatedAt should be auto-set on create")
	}
	if got.UpdatedAt == "" {
		t.Error("UpdatedAt should be auto-set on create")
	}

	createdAt := got.CreatedAt

	// Update — UpdatedAt should change but CreatedAt preserved
	if err := s.Update("party-ts", func(m *Manifest) {
		m.Title = "updated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err = s.Read("party-ts")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.CreatedAt != createdAt {
		t.Errorf("CreatedAt changed: got %q, want %q", got.CreatedAt, createdAt)
	}
	if got.UpdatedAt == "" {
		t.Error("UpdatedAt should be non-empty after update")
	}
}

func TestStore_UnknownFieldsSurviveUpdate(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	// Write a manifest with extra fields directly
	path := filepath.Join(s.root, "party-extra.json")
	raw := `{"party_id":"party-extra","cwd":"/tmp","parent_session":"party-m","initial_prompt":"test","created_at":"2026-01-01T00:00:00Z"}`
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Update via Store
	if err := s.Update("party-extra", func(m *Manifest) {
		m.Title = "modified"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	// Read back raw JSON and verify extra fields survived
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var check map[string]any
	if err := json.Unmarshal(data, &check); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if check["parent_session"] != "party-m" {
		t.Errorf("parent_session lost: got %v", check["parent_session"])
	}
	if check["initial_prompt"] != "test" {
		t.Errorf("initial_prompt lost: got %v", check["initial_prompt"])
	}
	if check["title"] != "modified" {
		t.Errorf("title not updated: got %v", check["title"])
	}
}

// ---------------------------------------------------------------------------
// ID validation
// ---------------------------------------------------------------------------

func TestStore_RejectsPathTraversal(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	badIDs := []string{
		"../../../etc/passwd",
		"party-../../evil",
		"party-ok/../../bad",
		"notparty-abc",
		"party-",
		"",
	}
	for _, id := range badIDs {
		if err := s.Create(Manifest{PartyID: id, Cwd: "/tmp"}); err == nil {
			t.Errorf("Create(%q) should have been rejected", id)
		}
		if _, err := s.Read(id); err == nil {
			t.Errorf("Read(%q) should have been rejected", id)
		}
	}
}

// ---------------------------------------------------------------------------
// Worker management
// ---------------------------------------------------------------------------

func TestStore_AddAndGetWorkers(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-master", SessionType: "master", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatalf("AddWorker w1: %v", err)
	}
	if err := s.AddWorker("party-master", "party-w2"); err != nil {
		t.Fatalf("AddWorker w2: %v", err)
	}

	workers, err := s.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}

	if len(workers) != 2 {
		t.Fatalf("workers count: got %d, want 2", len(workers))
	}
}

func TestStore_AddWorkerDeduplicates(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-dedup", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.AddWorker("party-dedup", "party-w1"); err != nil {
		t.Fatalf("AddWorker first: %v", err)
	}
	if err := s.AddWorker("party-dedup", "party-w1"); err != nil {
		t.Fatalf("AddWorker second: %v", err)
	}

	workers, err := s.GetWorkers("party-dedup")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if len(workers) != 1 {
		t.Fatalf("workers count: got %d, want 1 (deduplicated)", len(workers))
	}
}

func TestStore_RemoveWorker(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-rm", Cwd: "/tmp", Workers: []string{"party-w1", "party-w2"}}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.RemoveWorker("party-rm", "party-w1"); err != nil {
		t.Fatalf("RemoveWorker: %v", err)
	}

	workers, err := s.GetWorkers("party-rm")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if len(workers) != 1 {
		t.Fatalf("workers count: got %d, want 1", len(workers))
	}
	if workers[0] != "party-w2" {
		t.Errorf("remaining worker: got %q, want %q", workers[0], "party-w2")
	}
}

func TestStore_GetWorkersNil(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-empty", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	workers, err := s.GetWorkers("party-empty")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if workers != nil {
		t.Fatalf("workers: got %v, want nil", workers)
	}
}

// ---------------------------------------------------------------------------
// Flock-based locking
// ---------------------------------------------------------------------------

func TestStore_ConcurrentUpdates(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-conc", Cwd: "/tmp", Title: "start"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	const n = 20
	var wg sync.WaitGroup
	wg.Add(n)
	for i := range n {
		go func(i int) {
			defer wg.Done()
			wid := "party-cw" + string(rune('A'+i))
			if err := s.AddWorker("party-conc", wid); err != nil {
				t.Errorf("AddWorker(%d): %v", i, err)
			}
		}(i)
	}
	wg.Wait()

	workers, err := s.GetWorkers("party-conc")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if len(workers) != n {
		t.Errorf("workers count: got %d, want %d", len(workers), n)
	}
}

func TestStore_LockTimeout(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{PartyID: "party-lock", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Acquire the lock externally and hold it
	lockPath := filepath.Join(s.root, "party-lock.json.lock")
	lockFile, err := os.Create(lockPath)
	if err != nil {
		t.Fatalf("create lock file: %v", err)
	}
	if err := acquireFlock(lockFile, 5*time.Second); err != nil {
		lockFile.Close()
		t.Fatalf("acquire external lock: %v", err)
	}

	// Use a store with short timeout to trigger lock contention
	shortStore := &Store{root: s.root, lockTimeout: 100 * time.Millisecond}

	err = shortStore.Update("party-lock", func(m *Manifest) {
		m.Title = "blocked"
	})

	releaseFlock(lockFile)
	lockFile.Close()

	if err == nil {
		t.Fatal("expected lock timeout error, got nil")
	}
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

func TestDiscoverSessions_AllPartySessions(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	for _, id := range []string{"party-a", "party-b", "party-c"} {
		if err := s.Create(Manifest{PartyID: id, Cwd: "/tmp"}); err != nil {
			t.Fatalf("Create(%s): %v", id, err)
		}
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}

	if len(sessions) != 3 {
		t.Fatalf("session count: got %d, want 3", len(sessions))
	}
}

func TestDiscoverSessions_IgnoresNonPartyFiles(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{PartyID: "party-ok", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	nonParty := filepath.Join(s.root, "other-thing.json")
	if err := os.WriteFile(nonParty, []byte(`{"id":"other"}`), 0o644); err != nil {
		t.Fatalf("write non-party file: %v", err)
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}

	if len(sessions) != 1 {
		t.Fatalf("session count: got %d, want 1", len(sessions))
	}
	if sessions[0].PartyID != "party-ok" {
		t.Errorf("PartyID: got %q, want %q", sessions[0].PartyID, "party-ok")
	}
}

func TestDiscoverSessions_EmptyDir(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}
	if len(sessions) != 0 {
		t.Fatalf("session count: got %d, want 0", len(sessions))
	}
}

func TestDiscoverSessions_ToleratesCorruptManifest(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{PartyID: "party-good", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	corrupt := filepath.Join(s.root, "party-bad.json")
	if err := os.WriteFile(corrupt, []byte(`{invalid json`), 0o644); err != nil {
		t.Fatalf("write corrupt file: %v", err)
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}

	if len(sessions) != 1 {
		t.Fatalf("session count: got %d, want 1", len(sessions))
	}
}

func TestDiscoverSessions_IgnoresLockFiles(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{PartyID: "party-lk", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	lockFile := filepath.Join(s.root, "party-lk.json.lock")
	if err := os.WriteFile(lockFile, nil, 0o644); err != nil {
		t.Fatalf("write lock file: %v", err)
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("session count: got %d, want 1", len(sessions))
	}
}

func TestDiscoverSessions_FilenameIsCanonicalPartyID(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	// Write a manifest where JSON party_id disagrees with filename
	path := filepath.Join(s.root, "party-right.json")
	raw := `{"party_id":"party-wrong","cwd":"/tmp"}`
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}
	if len(sessions) != 1 {
		t.Fatalf("session count: got %d, want 1", len(sessions))
	}
	if sessions[0].PartyID != "party-right" {
		t.Errorf("PartyID: got %q, want %q (filename canonical)", sessions[0].PartyID, "party-right")
	}
}

func TestManifest_SanitizesMaliciousResumeIDs(t *testing.T) {
	t.Parallel()

	raw := []byte(`{
		"party_id": "party-test",
		"agents": [
			{"name": "claude", "role": "primary", "resume_id": "../../../etc/passwd"},
			{"name": "codex", "role": "companion", "resume_id": "thr-*"}
		],
		"claude_session_id": "sess/../etc",
		"codex_thread_id": "valid-uuid-123"
	}`)

	var m Manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if m.Agents[0].ResumeID != "" {
		t.Errorf("Claude resume_id with traversal should be blanked, got %q", m.Agents[0].ResumeID)
	}
	if m.Agents[1].ResumeID != "" {
		t.Errorf("Codex resume_id with glob meta should be blanked, got %q", m.Agents[1].ResumeID)
	}
	if m.ExtraString("claude_session_id") != "" {
		t.Errorf("Legacy claude_session_id with traversal should be cleared, got %q", m.ExtraString("claude_session_id"))
	}
	if got := m.ExtraString("codex_thread_id"); got != "valid-uuid-123" {
		t.Errorf("Safe codex_thread_id should pass through, got %q", got)
	}
}
