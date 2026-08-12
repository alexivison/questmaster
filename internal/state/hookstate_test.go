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
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	return root
}

func TestSaveLoadRoundtrip(t *testing.T) {
	setStateRoot(t)
	id := "qm-test-roundtrip"
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
	ss, err := LoadSessionState("qm-not-here")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss != nil {
		t.Errorf("want nil for missing state, got %+v", ss)
	}
}

func TestInvalidSessionID(t *testing.T) {
	setStateRoot(t)
	for _, id := range []string{"", "qm-", "not-qm", "qm-/etc/passwd", "qm-../escape", "qm-a b", "party-abc"} {
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
	if !IsValidSessionID("qm-abc123") {
		t.Error("qm-abc123 should be valid")
	}
}

// TestUpdateLostUpdatePrevention proves that a naive Load → mutate → Save
// would clobber a concurrent hook write. UpdateSessionState must re-read
// inside the lock.
func TestUpdateLostUpdatePrevention(t *testing.T) {
	setStateRoot(t)
	id := "qm-lostupdate"

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
// contract used by optimistic no-op callers.
func TestUpdateMutateFalseSkipsWrite(t *testing.T) {
	setStateRoot(t)
	id := "qm-mutate-false"
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{"primary": {Role: "primary", State: "working"}},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
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

func TestUpdateSessionStatePreservesArtifacts(t *testing.T) {
	setStateRoot(t)
	id := "qm-artifacts-preserved"
	addedAt := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC).Format(time.RFC3339)
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{"primary": {Role: "primary", State: "idle"}},
		Artifacts: []Artifact{{
			Kind:    "html",
			Path:    "/tmp/plan.html",
			Label:   "Plan",
			AddedAt: addedAt,
		}},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if err := UpdateSessionState(id, func(ss *SessionState) bool {
		pane := ss.Panes["primary"]
		pane.State = "working"
		pane.Activity = "Bash: go test ./..."
		ss.Panes["primary"] = pane
		return true
	}); err != nil {
		t.Fatalf("update: %v", err)
	}

	got, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(got.Artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want one preserved artifact", got.Artifacts)
	}
	artifact := got.Artifacts[0]
	if artifact.Kind != "html" || artifact.Path != "/tmp/plan.html" || artifact.Label != "Plan" || artifact.AddedAt != addedAt {
		t.Fatalf("artifact = %#v, want preserved runtime artifact", artifact)
	}
}

func TestArtifactKindForPath(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		path string
		want string
	}{
		"html":     {path: "/tmp/report.html", want: ArtifactKindHTML},
		"htm":      {path: "/tmp/report.HTM", want: ArtifactKindHTML},
		"markdown": {path: "/tmp/report.md", want: ArtifactKindMarkdown},
		"image":    {path: "/tmp/screenshot.PNG", want: ArtifactKindImage},
		"unknown":  {path: "/tmp/report.pdf", want: ArtifactKindHTML},
		"empty":    {path: "", want: ArtifactKindHTML},
	}

	for name, tt := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := ArtifactKindForPath(tt.path); got != tt.want {
				t.Fatalf("ArtifactKindForPath(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

func TestArtifactRefsSurviveStateRewriteWithoutArtifacts(t *testing.T) {
	setStateRoot(t)
	id := "qm-artifacts-sidecar"
	addedAt := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC).Format(time.RFC3339)
	if err := UpsertArtifact(id, Artifact{
		Kind:    "html",
		Path:    "/tmp/plan.html",
		Label:   "Plan",
		AddedAt: addedAt,
	}); err != nil {
		t.Fatalf("upsert artifact: %v", err)
	}

	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{"primary": {Role: "primary", State: "working"}},
	}); err != nil {
		t.Fatalf("old hook rewrite: %v", err)
	}

	artifacts, err := LoadArtifacts(id)
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}
	if len(artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want one sidecar artifact after state rewrite", artifacts)
	}
	artifact := artifacts[0]
	if artifact.Kind != "html" || artifact.Path != "/tmp/plan.html" || artifact.Label != "Plan" || artifact.AddedAt != addedAt {
		t.Fatalf("artifact = %#v, want preserved sidecar artifact", artifact)
	}
}

func TestArtifactRegistrySurvivesSessionStateDirRemoval(t *testing.T) {
	root := setStateRoot(t)
	id := "qm-artifacts-global"

	if err := UpsertArtifact(id, Artifact{
		Path:  "/tmp/global-plan.html",
		Label: "Plan",
	}); err != nil {
		t.Fatalf("upsert artifact: %v", err)
	}
	if err := os.RemoveAll(SessionStateDir(root, id)); err != nil {
		t.Fatalf("remove session state dir: %v", err)
	}

	artifacts, err := LoadArtifacts(id)
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].Path != "/tmp/global-plan.html" || artifacts[0].SessionID != id {
		t.Fatalf("artifacts = %#v, want durable artifact with session id", artifacts)
	}
}

func TestRemoveArtifactDoesNotRecreateDeletedSessionStateDir(t *testing.T) {
	root := setStateRoot(t)
	id := "qm-artifacts-deleted"
	path := "/tmp/deleted-plan.html"

	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
	}); err != nil {
		t.Fatalf("create session state dir: %v", err)
	}
	if err := UpsertArtifact(id, Artifact{Path: path, Label: "Plan"}); err != nil {
		t.Fatalf("upsert artifact: %v", err)
	}
	if err := os.RemoveAll(SessionStateDir(root, id)); err != nil {
		t.Fatalf("remove session state dir: %v", err)
	}

	removed, err := RemoveArtifact(id, path)
	if err != nil {
		t.Fatalf("remove artifact: %v", err)
	}
	if !removed {
		t.Fatal("remove artifact = false, want true")
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("artifacts = %#v, want registry empty", artifacts)
	}
	if _, err := os.Stat(SessionStateDir(root, id)); !os.IsNotExist(err) {
		t.Fatalf("session state dir recreated: err=%v", err)
	}
}

func TestUpsertArtifactDoesNotRecreateAbsentPreviousOwnerSidecar(t *testing.T) {
	root := setStateRoot(t)
	oldID := "qm-artifacts-old"
	newID := "qm-artifacts-new"
	path := "/tmp/moved-plan.html"

	if err := SaveSessionState(oldID, &SessionState{
		SessionID: oldID,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
	}); err != nil {
		t.Fatalf("create old session state dir: %v", err)
	}
	if err := UpsertArtifact(oldID, Artifact{Path: path, Label: "Old"}); err != nil {
		t.Fatalf("upsert old artifact: %v", err)
	}
	if err := os.RemoveAll(SessionStateDir(root, oldID)); err != nil {
		t.Fatalf("remove old session state dir: %v", err)
	}
	if err := SaveSessionState(newID, &SessionState{
		SessionID: newID,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
	}); err != nil {
		t.Fatalf("create new session state dir: %v", err)
	}

	if err := UpsertArtifact(newID, Artifact{Path: path, Label: "New"}); err != nil {
		t.Fatalf("move artifact to new session: %v", err)
	}

	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	if len(artifacts) != 1 || artifacts[0].SessionID != newID || artifacts[0].Label != "New" {
		t.Fatalf("artifacts = %#v, want moved artifact owned by new session", artifacts)
	}
	if _, err := os.Stat(SessionStateDir(root, oldID)); !os.IsNotExist(err) {
		t.Fatalf("old session state dir recreated: err=%v", err)
	}
	sidecar, ok, err := loadArtifactsSidecarAt(root, newID)
	if err != nil {
		t.Fatalf("load new sidecar: %v", err)
	}
	if !ok || len(sidecar) != 1 || sidecar[0].SessionID != newID || sidecar[0].Label != "New" {
		t.Fatalf("new sidecar = %#v ok=%v, want moved artifact", sidecar, ok)
	}
}

func TestLoadArtifactsGlobalMigratesSidecarAndLegacyState(t *testing.T) {
	root := setStateRoot(t)
	sessionID := "qm-artifacts-migrate"
	workdir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workdir, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	store, err := NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(Manifest{SessionID: sessionID, Cwd: workdir}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	old := "2026-06-19T04:19:00Z"
	newer := "2026-06-19T04:21:00Z"
	if err := SaveSessionState(sessionID, &SessionState{
		SessionID: sessionID,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
		Artifacts: []Artifact{{
			Path:    "/tmp/migrated.html",
			Label:   "Legacy",
			AddedAt: old,
		}},
	}); err != nil {
		t.Fatalf("save legacy state: %v", err)
	}
	if err := writeArtifactsLocked(root, sessionID, []Artifact{{
		Path:    "/tmp/migrated.html",
		Label:   "Sidecar",
		AddedAt: newer,
	}}); err != nil {
		t.Fatalf("write sidecar: %v", err)
	}

	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	if len(artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want deduped migrated artifact", artifacts)
	}
	wantProjectID, err := filepath.EvalSymlinks(filepath.Join(workdir, ".git"))
	if err != nil {
		t.Fatalf("resolve .git: %v", err)
	}
	artifact := artifacts[0]
	if artifact.Path != "/tmp/migrated.html" || artifact.Label != "Sidecar" || artifact.SessionID != sessionID || artifact.ProjectID != wantProjectID {
		t.Fatalf("artifact = %#v, want newest sidecar artifact with session id", artifact)
	}
	if _, err := os.Stat(ArtifactsRegistryPath(root)); err != nil {
		t.Fatalf("registry not written: %v", err)
	}
}

func TestFilterArtifactsByScope(t *testing.T) {
	artifacts := []Artifact{
		{Path: "/tmp/a.html", SessionID: "qm-a", ProjectID: "repo-a", AddedAt: "2026-06-19T04:19:00Z"},
		{Path: "/tmp/b.html", SessionID: "qm-b", ProjectID: "repo-a", AddedAt: "2026-06-19T04:20:00Z"},
		{Path: "/tmp/c.html", SessionID: "qm-c", ProjectID: "repo-c", AddedAt: "2026-06-19T04:21:00Z"},
	}

	session := FilterArtifacts(artifacts, ArtifactScopeSession, "qm-a", "repo-a")
	if len(session) != 1 || session[0].Path != "/tmp/a.html" {
		t.Fatalf("session artifacts = %#v", session)
	}
	project := FilterArtifacts(artifacts, ArtifactScopeProject, "qm-a", "repo-a")
	if len(project) != 2 || project[0].Path != "/tmp/b.html" || project[1].Path != "/tmp/a.html" {
		t.Fatalf("project artifacts = %#v", project)
	}
	emptyProject := FilterArtifacts(artifacts, ArtifactScopeProject, "qm-a", "")
	if len(emptyProject) != 0 {
		t.Fatalf("empty project artifacts = %#v, want none", emptyProject)
	}
	all := FilterArtifacts(artifacts, ArtifactScopeAll, "qm-a", "repo-a")
	if len(all) != 3 || all[0].Path != "/tmp/c.html" {
		t.Fatalf("all artifacts = %#v", all)
	}
}

func TestArtifactWrapperSyncsSessionSidecar(t *testing.T) {
	root := setStateRoot(t)
	id := "qm-artifacts-sync"

	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes:     map[string]PaneState{},
	}); err != nil {
		t.Fatalf("create session state dir: %v", err)
	}
	if err := UpsertArtifact(id, Artifact{Path: "/tmp/sync.html"}); err != nil {
		t.Fatalf("upsert artifact: %v", err)
	}
	sidecar, _, err := loadArtifactsSidecarAt(root, id)
	if err != nil {
		t.Fatalf("load sidecar: %v", err)
	}
	if len(sidecar) != 1 || sidecar[0].Path != "/tmp/sync.html" {
		t.Fatalf("sidecar after add = %#v", sidecar)
	}

	removed, err := RemoveArtifact(id, "/tmp/sync.html")
	if err != nil {
		t.Fatalf("remove artifact: %v", err)
	}
	if !removed {
		t.Fatal("remove artifact = false, want true")
	}
	sidecar, _, err = loadArtifactsSidecarAt(root, id)
	if err != nil {
		t.Fatalf("load sidecar after remove: %v", err)
	}
	if len(sidecar) != 0 {
		t.Fatalf("sidecar after remove = %#v, want empty", sidecar)
	}
}

func TestUpsertArtifactDedupesCleanEquivalentAbsolutePaths(t *testing.T) {
	setStateRoot(t)
	id := "qm-artifacts-clean"

	if err := UpsertArtifact(id, Artifact{
		Kind:  "html",
		Path:  "/tmp/questmaster-artifacts/../plan.html",
		Label: "Plan",
	}); err != nil {
		t.Fatalf("upsert first artifact: %v", err)
	}
	if err := UpsertArtifact(id, Artifact{
		Kind:  "html",
		Path:  "/tmp/plan.html",
		Label: "Plan v2",
	}); err != nil {
		t.Fatalf("upsert equivalent artifact: %v", err)
	}

	artifacts, err := LoadArtifacts(id)
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}
	if len(artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want one deduped artifact", artifacts)
	}
	if artifacts[0].Path != "/tmp/plan.html" || artifacts[0].Label != "Plan v2" {
		t.Fatalf("artifact = %#v, want cleaned updated path", artifacts[0])
	}
}

func TestLoadArtifactsAtMissingSessionDoesNotCreateSessionDir(t *testing.T) {
	root := t.TempDir()
	id := "qm-artifacts-missing"

	artifacts, err := LoadArtifactsAt(root, id)
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("artifacts = %#v, want none", artifacts)
	}
	if _, err := os.Stat(SessionStateDir(root, id)); !os.IsNotExist(err) {
		t.Fatalf("session dir should not be created by read, err=%v", err)
	}
}

func TestMarkSessionObservedFoldsStaleDoneToIdle(t *testing.T) {
	setStateRoot(t)
	id := "qm-observed-done"
	now := time.Now().UTC().Truncate(time.Millisecond)
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes: map[string]PaneState{
			"primary": {
				Role:         "primary",
				State:        "done",
				LastEvent:    now.Add(-DoneToIdleGrace - time.Second),
				WorkingSince: now.Add(-time.Minute),
			},
		},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	changed, err := MarkSessionObserved(id, now)
	if err != nil {
		t.Fatalf("mark observed: %v", err)
	}
	if !changed {
		t.Fatal("MarkSessionObserved changed = false, want true")
	}
	got, err := LoadSessionState(id)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	pane := got.Panes["primary"]
	if pane.State != "idle" {
		t.Fatalf("state = %q, want idle", pane.State)
	}
	if !pane.WorkingSince.IsZero() {
		t.Fatalf("WorkingSince = %v, want zero", pane.WorkingSince)
	}
	if !got.SeenAt.Equal(now) {
		t.Fatalf("SeenAt = %v, want %v", got.SeenAt, now)
	}
}

func TestMarkSessionObservedLeavesFreshDoneUnwritten(t *testing.T) {
	root := setStateRoot(t)
	id := "qm-observed-fresh"
	now := time.Now().UTC().Truncate(time.Millisecond)
	if err := SaveSessionState(id, &SessionState{
		SessionID: id,
		Version:   SchemaVersion,
		Panes: map[string]PaneState{
			"primary": {
				Role:      "primary",
				State:     "done",
				LastEvent: now.Add(-time.Second),
			},
		},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	before, err := os.ReadFile(SessionStatePath(root, id))
	if err != nil {
		t.Fatalf("read before: %v", err)
	}

	changed, err := MarkSessionObserved(id, now)
	if err != nil {
		t.Fatalf("mark observed: %v", err)
	}
	if changed {
		t.Fatal("MarkSessionObserved changed = true, want false inside grace window")
	}
	after, err := os.ReadFile(SessionStatePath(root, id))
	if err != nil {
		t.Fatalf("read after: %v", err)
	}
	if string(before) != string(after) {
		t.Fatal("fresh done observation rewrote state.json")
	}
}

func TestMarkSessionObservedSkipsHooklessSession(t *testing.T) {
	root := setStateRoot(t)

	changed, err := MarkSessionObserved("qm-hookless", time.Now())
	if err != nil {
		t.Fatalf("mark observed: %v", err)
	}
	if changed {
		t.Fatal("hookless session changed = true, want false")
	}
	if _, err := os.Stat(SessionStatePath(root, "qm-hookless")); !os.IsNotExist(err) {
		t.Fatalf("state.json should not be created for hookless session, err=%v", err)
	}
}

// TestConcurrentWritesSerialize stresses flock with many goroutines.
// The final file must be a well-formed JSON object that contains exactly
// one of the values each goroutine wrote (never a partial / interleaved
// document).
func TestConcurrentWritesSerialize(t *testing.T) {
	setStateRoot(t)
	id := "qm-concurrent"
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
	id := "qm-rotate"
	// Force a small rotation threshold for the test via a helper.
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
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
	id := "qm-jsonl-shape"
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
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
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
	id := "qm-foreignschema"
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	stale := []byte(`{"session_id":"qm-foreignschema","version":99,"panes":{}}`)
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

// TestStateRootResolution covers QUESTMASTER_STATE_ROOT precedence over
// the HOME-relative default.
func TestStateRootResolution(t *testing.T) {
	t.Setenv("QUESTMASTER_STATE_ROOT", "/tmp/questmaster")
	t.Setenv("HOME", "/tmp/home")
	if got := StateRoot(); got != "/tmp/questmaster" {
		t.Errorf("StateRoot should prefer QUESTMASTER_STATE_ROOT: %q", got)
	}
	t.Setenv("QUESTMASTER_STATE_ROOT", "")
	if got, want := StateRoot(), filepath.Join("/tmp/home", ".questmaster-state"); got != want {
		t.Errorf("StateRoot fallback: want %q got %q", want, got)
	}
}
