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
		SessionID:  "qm-abc",
		CreatedAt:  "2026-03-20T10:00:00Z",
		UpdatedAt:  "2026-03-20T11:00:00Z",
		Title:      "test session",
		Cwd:        "/tmp/work",
		WindowName: "main",
		Agents: []AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/local/bin/claude", ResumeID: "claude-1", Window: 1},
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

	if got.SessionID != m.SessionID || got.CreatedAt != m.CreatedAt ||
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
		SessionID:   "qm-x",
		SessionType: "master",
		Workers:     []string{"qm-w1", "qm-w2"},
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}

	wantKeys := []string{"session_id", "session_type", "workers"}
	for _, k := range wantKeys {
		if _, ok := raw[k]; !ok {
			t.Errorf("expected JSON key %q, not found in %v", k, raw)
		}
	}
}

func TestNewStoreTightensStateRootPermissions(t *testing.T) {
	root := filepath.Join(t.TempDir(), "state")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir state root: %v", err)
	}
	if err := os.Chmod(root, 0o755); err != nil {
		t.Fatalf("chmod state root: %v", err)
	}

	if _, err := NewStore(root); err != nil {
		t.Fatalf("NewStore: %v", err)
	}

	info, err := os.Stat(root)
	if err != nil {
		t.Fatalf("stat state root: %v", err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("state root mode = %03o, want 700", got)
	}
}

func TestManifest_OlderManifestMissingOptionalFields(t *testing.T) {
	t.Parallel()

	older := `{"session_id":"qm-old","created_at":"2026-01-01T00:00:00Z","cwd":"/old"}`

	var m Manifest
	if err := json.Unmarshal([]byte(older), &m); err != nil {
		t.Fatalf("unmarshal older manifest: %v", err)
	}

	if m.SessionID != "qm-old" {
		t.Errorf("session_id: got %q, want %q", m.SessionID, "qm-old")
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
	input := `{"session_id":"qm-f","cwd":"/f","parent_session":"qm-master","initial_prompt":"hello","claude_session_id":"abc123"}`

	var m Manifest
	if err := json.Unmarshal([]byte(input), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if m.SessionID != "qm-f" {
		t.Errorf("session_id: got %q, want %q", m.SessionID, "qm-f")
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
		SessionID: "qm-test",
		CreatedAt: "2026-03-20T10:00:00Z",
		UpdatedAt: "2026-03-20T10:00:00Z",
		Title:     "test",
		Cwd:       "/tmp",
	}

	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := s.Read("qm-test")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}

	if got.SessionID != "qm-test" {
		t.Errorf("SessionID: got %q, want %q", got.SessionID, "qm-test")
	}
	if got.Title != "test" {
		t.Errorf("Title: got %q, want %q", got.Title, "test")
	}
}

func TestStore_CreateDuplicate(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{SessionID: "qm-dup", Cwd: "/tmp"}
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

	_, err := s.Read("qm-nonexistent")
	if err == nil {
		t.Fatal("expected error on Read of nonexistent manifest, got nil")
	}
}

func TestStore_Update(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{
		SessionID: "qm-upd",
		Title:     "original",
		Cwd:       "/tmp",
	}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Update("qm-upd", func(m *Manifest) {
		m.Title = "updated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("qm-upd")
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

	err := s.Update("qm-ghost", func(m *Manifest) {
		m.Title = "nope"
	})
	if err == nil {
		t.Fatal("expected error on Update of nonexistent manifest, got nil")
	}
}

func TestStore_UpdatePreservesSessionID(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{SessionID: "qm-inv", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Callback tries to mutate SessionID — should be overridden
	if err := s.Update("qm-inv", func(m *Manifest) {
		m.SessionID = "qm-other"
		m.Title = "mutated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("qm-inv")
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	if got.SessionID != "qm-inv" {
		t.Errorf("SessionID: got %q, want %q", got.SessionID, "qm-inv")
	}
	if got.Title != "mutated" {
		t.Errorf("Title: got %q, want %q", got.Title, "mutated")
	}
}

func TestStore_UpdateViaField(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{SessionID: "qm-sf", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Update("qm-sf", func(m *Manifest) {
		m.SessionType = "master"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err := s.Read("qm-sf")
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

	m := Manifest{SessionID: "qm-del", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.Delete("qm-del"); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	_, err := s.Read("qm-del")
	if err == nil {
		t.Fatal("expected error after Delete, got nil")
	}
}

func TestStore_DeleteNotFound(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	err := s.Delete("qm-nope")
	if err == nil {
		t.Fatal("expected error on Delete of nonexistent manifest, got nil")
	}
}

func TestStore_TimestampsAutoManaged(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	// Create without timestamps — they should be auto-set
	m := Manifest{SessionID: "qm-ts", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := s.Read("qm-ts")
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
	if err := s.Update("qm-ts", func(m *Manifest) {
		m.Title = "updated"
	}); err != nil {
		t.Fatalf("Update: %v", err)
	}

	got, err = s.Read("qm-ts")
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
	path := filepath.Join(s.root, "qm-extra.json")
	raw := `{"session_id":"qm-extra","cwd":"/tmp","parent_session":"qm-m","initial_prompt":"test","created_at":"2026-01-01T00:00:00Z"}`
	if err := os.WriteFile(path, []byte(raw), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Update via Store
	if err := s.Update("qm-extra", func(m *Manifest) {
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

	if check["parent_session"] != "qm-m" {
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

func TestStore_AcceptsQMIDs(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	id := "qm-valid_123"
	if err := s.Create(Manifest{SessionID: id, Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create(%q): %v", id, err)
	}
	if _, err := s.Read(id); err != nil {
		t.Fatalf("Read(%q): %v", id, err)
	}
}

func TestStore_RejectsPathTraversal(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	badIDs := []string{
		"../../../etc/passwd",
		"qm-../../evil",
		"qm-ok/../../bad",
		"notqm-abc",
		"party-abc",
		"qm-",
		"",
	}
	for _, id := range badIDs {
		if err := s.Create(Manifest{SessionID: id, Cwd: "/tmp"}); err == nil {
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

	m := Manifest{SessionID: "qm-master", SessionType: "master", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.AddWorker("qm-master", "qm-w1"); err != nil {
		t.Fatalf("AddWorker w1: %v", err)
	}
	if err := s.AddWorker("qm-master", "qm-w2"); err != nil {
		t.Fatalf("AddWorker w2: %v", err)
	}

	workers, err := s.GetWorkers("qm-master")
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

	m := Manifest{SessionID: "qm-dedup", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.AddWorker("qm-dedup", "qm-w1"); err != nil {
		t.Fatalf("AddWorker first: %v", err)
	}
	if err := s.AddWorker("qm-dedup", "qm-w1"); err != nil {
		t.Fatalf("AddWorker second: %v", err)
	}

	workers, err := s.GetWorkers("qm-dedup")
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

	m := Manifest{SessionID: "qm-rm", Cwd: "/tmp", Workers: []string{"qm-w1", "qm-w2"}}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	if err := s.RemoveWorker("qm-rm", "qm-w1"); err != nil {
		t.Fatalf("RemoveWorker: %v", err)
	}

	workers, err := s.GetWorkers("qm-rm")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if len(workers) != 1 {
		t.Fatalf("workers count: got %d, want 1", len(workers))
	}
	if workers[0] != "qm-w2" {
		t.Errorf("remaining worker: got %q, want %q", workers[0], "qm-w2")
	}
}

func TestStore_GetWorkersNil(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{SessionID: "qm-empty", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	workers, err := s.GetWorkers("qm-empty")
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

	m := Manifest{SessionID: "qm-conc", Cwd: "/tmp", Title: "start"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	const n = 20
	var wg sync.WaitGroup
	wg.Add(n)
	for i := range n {
		go func(i int) {
			defer wg.Done()
			wid := "qm-cw" + string(rune('A'+i))
			if err := s.AddWorker("qm-conc", wid); err != nil {
				t.Errorf("AddWorker(%d): %v", i, err)
			}
		}(i)
	}
	wg.Wait()

	workers, err := s.GetWorkers("qm-conc")
	if err != nil {
		t.Fatalf("GetWorkers: %v", err)
	}
	if len(workers) != n {
		t.Errorf("workers count: got %d, want %d", len(workers), n)
	}
}

func TestStore_LockWaitsUntilReleased(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	m := Manifest{SessionID: "qm-lock", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create: %v", err)
	}

	// Acquire the lock externally and hold it
	lockPath := filepath.Join(s.root, "qm-lock.json.lock")
	lockFile, err := os.Create(lockPath)
	if err != nil {
		t.Fatalf("create lock file: %v", err)
	}
	if err := acquireFlock(lockFile); err != nil {
		lockFile.Close()
		t.Fatalf("acquire external lock: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- s.Update("qm-lock", func(m *Manifest) {
			m.Title = "blocked"
		})
	}()

	select {
	case err := <-done:
		releaseFlock(lockFile)
		lockFile.Close()
		t.Fatalf("update returned before lock release: %v", err)
	case <-time.After(50 * time.Millisecond):
	}

	releaseFlock(lockFile)
	lockFile.Close()

	if err := <-done; err != nil {
		t.Fatalf("update after lock release: %v", err)
	}
	got, err := s.Read("qm-lock")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got.Title != "blocked" {
		t.Fatalf("title: got %q, want %q", got.Title, "blocked")
	}
}

func TestStore_CreateAutoMakesMissingRoot(t *testing.T) {
	t.Parallel()
	// Simulate a fresh install: parent exists, state root does not.
	root := filepath.Join(t.TempDir(), ".questmaster-state")
	s := OpenStore(root)

	m := Manifest{SessionID: "qm-fresh", Cwd: "/tmp"}
	if err := s.Create(m); err != nil {
		t.Fatalf("Create on missing root: %v", err)
	}

	if _, err := os.Stat(root); err != nil {
		t.Fatalf("state root not created: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

func TestDiscoverSessions_AllSessions(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	for _, id := range []string{"qm-a", "qm-b", "qm-c"} {
		if err := s.Create(Manifest{SessionID: id, Cwd: "/tmp"}); err != nil {
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

func TestDiscoverSessions_IncludesQMSkipsUnrelated(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	if err := s.Create(Manifest{SessionID: "qm-ok", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	for name, body := range map[string]string{
		"other-thing.json":  `{"id":"other"}`,
		"party-legacy.json": `{"session_id":"party-legacy"}`,
		"qm-.json":          `{"session_id":"qm-"}`,
	} {
		if err := os.WriteFile(filepath.Join(s.root, name), []byte(body), 0o644); err != nil {
			t.Fatalf("write unrelated file %s: %v", name, err)
		}
	}

	sessions, err := s.DiscoverSessions()
	if err != nil {
		t.Fatalf("DiscoverSessions: %v", err)
	}

	got := map[string]bool{}
	for _, session := range sessions {
		got[session.SessionID] = true
	}
	if !got["qm-ok"] {
		t.Fatalf("DiscoverSessions missing qm-ok: %+v", sessions)
	}
	if len(sessions) != 1 {
		t.Fatalf("session count: got %d, want 1", len(sessions))
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

	if err := s.Create(Manifest{SessionID: "qm-good", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	corrupt := filepath.Join(s.root, "qm-bad.json")
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

	if err := s.Create(Manifest{SessionID: "qm-lk", Cwd: "/tmp"}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	lockFile := filepath.Join(s.root, "qm-lk.json.lock")
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

func TestDiscoverSessions_FilenameIsCanonicalSessionID(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)

	// Write a manifest where JSON session_id disagrees with filename
	path := filepath.Join(s.root, "qm-right.json")
	raw := `{"session_id":"qm-wrong","cwd":"/tmp"}`
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
	if sessions[0].SessionID != "qm-right" {
		t.Errorf("SessionID: got %q, want %q (filename canonical)", sessions[0].SessionID, "qm-right")
	}
}

func TestManifest_SanitizesMaliciousResumeIDs(t *testing.T) {
	t.Parallel()

	raw := []byte(`{
		"session_id": "qm-test",
		"agents": [
			{"name": "claude", "role": "primary", "resume_id": "../../../etc/passwd"},
			{"name": "codex", "role": "secondary", "resume_id": "thr-*"}
		],
		"claude_session_id": "sess/../etc",
		"codex_thread_id": "valid-uuid-123",
		"pi_session_id": "bad*glob",
		"opencode_session_id": "ses/unsafe"
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
	if got := m.ExtraString("pi_session_id"); got != "" {
		t.Errorf("Unsafe pi_session_id should be cleared, got %q", got)
	}
	if got := m.ExtraString("opencode_session_id"); got != "" {
		t.Errorf("Unsafe opencode_session_id should be cleared, got %q", got)
	}
}
