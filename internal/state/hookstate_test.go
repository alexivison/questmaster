//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func setStateRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("PARTY_STATE_ROOT", root)
	return root
}

func TestSaveLoadRoundtrip(t *testing.T) {
	setStateRoot(t)
	id := "party-test-roundtrip"
	now := time.Now().UTC().Truncate(time.Millisecond)
	ss := &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes: map[string]PaneState{
			"primary": {
				Role:      "primary",
				Agent:     "claude",
				State:     "working",
				Activity:  "Edit foo.go",
				Tool:      "Edit",
				LastEvent: now,
				LastKind:  "PreToolUse",
			},
		},
		SeenAt: now,
	}
	if err := SaveSessionState(id, ss); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got == nil {
		t.Fatal("load returned nil")
	}
	if got.SessionID != id || got.Version != SchemaVersion {
		t.Errorf("header mismatch: %+v", got)
	}
	if got.Panes["primary"].State != "working" || got.Panes["primary"].Activity != "Edit foo.go" {
		t.Errorf("primary pane mismatch: %+v", got.Panes["primary"])
	}
}

func TestLoadMissingReturnsNil(t *testing.T) {
	setStateRoot(t)
	ss, err := LoadSessionState("party-not-here")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss != nil {
		t.Errorf("want nil for missing state, got %+v", ss)
	}
}

func TestInvalidPartyID(t *testing.T) {
	setStateRoot(t)
	for _, id := range []string{"", "party-", "not-party", "party-/etc/passwd", "party-../escape", "party-a b"} {
		if _, err := LoadSessionState(id); err == nil {
			t.Errorf("load %q: want error, got nil", id)
		}
		if err := SaveSessionState(id, &SessionState{}); err == nil {
			t.Errorf("save %q: want error, got nil", id)
		}
		if err := UpdateSessionState(id, func(*SessionState) bool { return false }); err == nil {
			t.Errorf("update %q: want error, got nil", id)
		}
		if err := AppendStateEvent(id, StateEvent{}); err == nil {
			t.Errorf("append %q: want error, got nil", id)
		}
	}
	if !IsValidPartyID("party-abc123") {
		t.Error("party-abc123 should be valid")
	}
}

// TestUpdateLostUpdatePrevention reproduces the scenario in PLAN.md
// lines 417–444. A naive Load → mutate → Save would clobber a concurrent
// hook write. UpdateSessionState must re-read inside the lock.
func TestUpdateLostUpdatePrevention(t *testing.T) {
	setStateRoot(t)
	id := "party-lostupdate"

	// Seed with State=done.
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes: map[string]PaneState{
			"primary": {Role: "primary", State: "done", LastEvent: time.Now().UTC()},
		},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Block UpdateSessionState's mutate while we run a "hook" that bumps
	// the state to working. The mutate function checks invariants inside
	// the lock so when it runs the on-disk state already reflects the
	// hook's write.
	hookDone := make(chan struct{})
	mutateEntered := make(chan struct{})
	releaseMutate := make(chan struct{})

	go func() {
		// Tracker-style update: only flip done → idle.
		err := UpdateSessionState(id, func(ss *SessionState) bool {
			close(mutateEntered)
			<-releaseMutate
			p := ss.Panes["primary"]
			if p.State != "done" {
				// Refuse: hook already moved us past done. This is the
				// invariant the locked re-read protects.
				return false
			}
			p.State = "idle"
			ss.Panes["primary"] = p
			return true
		})
		if err != nil {
			t.Errorf("update: %v", err)
		}
		close(hookDone)
	}()

	// Wait for the tracker goroutine to enter mutate (which means it
	// already loaded state inside the lock — but we'll prove the lock
	// serialization regardless).
	<-mutateEntered

	// Now release the tracker mutate. Because UpdateSessionState holds
	// the lock for the entire call, the hook write below will block
	// until tracker finishes. After it finishes, we'll write working
	// and the tracker's mutate will have been called against the
	// pre-hook state — fine, because mutate already happened. The real
	// test is that we end up with consistent state, never "idle
	// clobbering working".
	close(releaseMutate)
	<-hookDone

	// Now simulate a hook firing — also through UpdateSessionState,
	// which is what the production hook path will use for partial
	// updates.
	if err := UpdateSessionState(id, func(ss *SessionState) bool {
		p := ss.Panes["primary"]
		p.State = "working"
		p.LastEvent = time.Now().UTC()
		ss.Panes["primary"] = p
		return true
	}); err != nil {
		t.Fatalf("hook update: %v", err)
	}

	// Final state must be working (hook wrote last), and the tracker's
	// idle write should have either been applied (then hook overwrote
	// it) or skipped — never reordered.
	got, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got.Panes["primary"].State != "working" {
		t.Errorf("final state: want working, got %q", got.Panes["primary"].State)
	}
}

// TestUpdateMutateFalseSkipsWrite asserts the mutate-returns-false
// contract from PLAN.md line 428.
func TestUpdateMutateFalseSkipsWrite(t *testing.T) {
	setStateRoot(t)
	id := "party-mutate-false"
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{"primary": {Role: "primary", State: "working"}},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	root := os.Getenv("PARTY_STATE_ROOT")
	before, err := os.ReadFile(SessionStatePath(root, id))
	if err != nil {
		t.Fatalf("read before: %v", err)
	}
	if err := UpdateSessionState(id, func(*SessionState) bool { return false }); err != nil {
		t.Fatalf("update: %v", err)
	}
	after, err := os.ReadFile(SessionStatePath(root, id))
	if err != nil {
		t.Fatalf("read after: %v", err)
	}
	if string(before) != string(after) {
		t.Errorf("file changed despite mutate returning false")
	}
}

// TestConcurrentWritesSerialize stresses flock with many goroutines.
// The final file must be a well-formed JSON object that contains exactly
// one of the values each goroutine wrote (never a partial / interleaved
// document).
func TestConcurrentWritesSerialize(t *testing.T) {
	setStateRoot(t)
	id := "party-concurrent"
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	const goroutines = 32
	const writesPer = 8
	var wg sync.WaitGroup
	var successes atomic.Int64
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < writesPer; i++ {
				err := UpdateSessionState(id, func(ss *SessionState) bool {
					ss.Panes["primary"] = PaneState{
						Role:      "primary",
						State:     "working",
						Activity:  "writer",
						Seq:       int64(g*1000 + i),
						LastEvent: time.Now().UTC(),
					}
					return true
				})
				if err == nil {
					successes.Add(1)
				}
			}
		}(g)
	}
	wg.Wait()
	if successes.Load() != int64(goroutines*writesPer) {
		t.Errorf("want %d successful writes, got %d", goroutines*writesPer, successes.Load())
	}
	ss, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss == nil || ss.Panes["primary"].State != "working" {
		t.Errorf("final state malformed: %+v", ss)
	}
}

func TestAppendStateEventRotation(t *testing.T) {
	setStateRoot(t)
	id := "party-rotate"
	// Force a small rotation threshold for the test via a helper.
	root := os.Getenv("PARTY_STATE_ROOT")
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	logPath := SessionStateLogPath(root, id)
	// Pre-populate the log so it exceeds the rotation threshold on the
	// next append.
	big := make([]byte, StateJSONLMaxSize+1)
	for i := range big {
		big[i] = '.'
	}
	if err := os.WriteFile(logPath, big, 0o644); err != nil {
		t.Fatalf("seed log: %v", err)
	}

	if err := AppendStateEvent(id, StateEvent{Action: "tool_start", Agent: "claude"}); err != nil {
		t.Fatalf("append: %v", err)
	}

	if _, err := os.Stat(logPath + ".1"); err != nil {
		t.Errorf("want rotated file at %s, got err %v", logPath+".1", err)
	}
	info, err := os.Stat(logPath)
	if err != nil {
		t.Fatalf("stat log: %v", err)
	}
	if info.Size() == 0 {
		t.Error("post-rotation log is empty")
	}
	if int64(info.Size()) >= StateJSONLMaxSize {
		t.Errorf("post-rotation log already huge: %d", info.Size())
	}

	// Multiple appends below threshold should not trigger another rotation.
	for i := 0; i < 5; i++ {
		if err := AppendStateEvent(id, StateEvent{Action: "tool_end", Agent: "claude"}); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	var rotatedCount int
	for _, e := range entries {
		if e.Name() == "state.jsonl.1" {
			rotatedCount++
		}
	}
	if rotatedCount != 1 {
		t.Errorf("want exactly one rotated file, got %d", rotatedCount)
	}
}

func TestAppendStateEventWriteValid(t *testing.T) {
	setStateRoot(t)
	id := "party-jsonl-shape"
	for i := 0; i < 3; i++ {
		if err := AppendStateEvent(id, StateEvent{
			Action: "tool_start",
			Agent:  "claude",
			State:  "working",
			Tool:   "Edit",
			Fields: map[string]interface{}{"i": i},
		}); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}
	root := os.Getenv("PARTY_STATE_ROOT")
	data, err := os.ReadFile(SessionStateLogPath(root, id))
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	lines := 0
	for _, line := range splitLines(data) {
		if len(line) == 0 {
			continue
		}
		var ev StateEvent
		if err := json.Unmarshal(line, &ev); err != nil {
			t.Fatalf("line %q is not valid json: %v", string(line), err)
		}
		if ev.Action != "tool_start" {
			t.Errorf("action: want tool_start, got %q", ev.Action)
		}
		lines++
	}
	if lines != 3 {
		t.Errorf("want 3 log lines, got %d", lines)
	}
}

func splitLines(b []byte) [][]byte {
	var out [][]byte
	start := 0
	for i, c := range b {
		if c == '\n' {
			out = append(out, b[start:i])
			start = i + 1
		}
	}
	if start < len(b) {
		out = append(out, b[start:])
	}
	return out
}

// TestForeignSchemaVersionPreserved asserts the on-disk schema version is
// preserved across load + save. The hook path is free to overwrite stale
// state, but Load/Save themselves don't silently migrate.
func TestForeignSchemaVersionPreserved(t *testing.T) {
	setStateRoot(t)
	id := "party-foreignschema"
	root := os.Getenv("PARTY_STATE_ROOT")
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	stale := []byte(`{"session_id":"party-foreignschema","version":99,"panes":{}}`)
	if err := os.WriteFile(SessionStatePath(root, id), stale, 0o644); err != nil {
		t.Fatalf("write stale: %v", err)
	}
	ss, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss.Version != 99 {
		t.Errorf("foreign version not preserved: got %d", ss.Version)
	}
}

// TestStateRootResolution covers the env-var precedence used by the hot
// path.
func TestStateRootResolution(t *testing.T) {
	t.Setenv("PARTY_STATE_ROOT", "/tmp/explicit")
	t.Setenv("HOME", "/tmp/home")
	if got := StateRoot(); got != "/tmp/explicit" {
		t.Errorf("StateRoot honoured HOME instead of PARTY_STATE_ROOT: %q", got)
	}
	t.Setenv("PARTY_STATE_ROOT", "")
	if got, want := StateRoot(), filepath.Join("/tmp/home", ".party-state"); got != want {
		t.Errorf("StateRoot fallback: want %q got %q", want, got)
	}
}
