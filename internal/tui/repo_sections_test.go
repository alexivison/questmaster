//go:build linux || darwin

package tui

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func sessionIDs(rows []SessionRow) []string {
	ids := make([]string, len(rows))
	for i, row := range rows {
		ids[i] = row.ID
	}
	return ids
}

func TestGroupRowsByRepoOrdersSectionsAlphabeticallyUngroupedLast(t *testing.T) {
	t.Parallel()

	// Tree-ordered input as orderSessionRows would emit: a master with its
	// worker, an ungrouped standalone, and a standalone in an earlier-named
	// repo. The worker carries no repo of its own; grouping must fold it under
	// its master's repo.
	rows := []SessionRow{
		{ID: "m-zebra", SessionType: "master", RepoIdentity: "/z/.git", RepoName: "zebra", RepoColor: "green"},
		{ID: "w-zebra", SessionType: "worker", ParentID: "m-zebra"},
		{ID: "s-none", SessionType: "standalone"},
		{ID: "s-apple", SessionType: "standalone", RepoIdentity: "/a/.git", RepoName: "apple"},
	}

	got := groupRowsByRepo(rows)
	want := []string{"s-apple", "m-zebra", "w-zebra", "s-none"}
	if gotIDs := sessionIDs(got); !equalStrings(gotIDs, want) {
		t.Fatalf("order = %v, want %v", gotIDs, want)
	}

	// The worker folds under its master's repo (identity, name, and color
	// propagate) so it groups, renders, and recolors with the tree.
	for _, row := range got {
		if row.ID == "w-zebra" {
			if row.RepoIdentity != "/z/.git" || row.RepoName != "zebra" || row.RepoColor != "green" {
				t.Fatalf("worker repo = %+v, want master's /z/.git zebra green", row)
			}
		}
	}
}

func TestGroupRowsByRepoOrphanWorkerKeepsOwnRepoSection(t *testing.T) {
	t.Parallel()

	// An orphan worker (its master was deleted) is appended after masters by
	// orderSessionRows. It is not absorbed into another tree; it keeps its own
	// resolved repo and groups in that section. One with no repo lands ungrouped.
	rows := []SessionRow{
		{ID: "m-apple", SessionType: "master", RepoIdentity: "/a/.git", RepoName: "apple"},
		{ID: "orphan-apple", SessionType: "worker", ParentID: "gone", RepoIdentity: "/a/.git", RepoName: "apple"},
		{ID: "orphan-loose", SessionType: "worker", ParentID: "gone"},
	}

	got := groupRowsByRepo(rows)
	want := []string{"m-apple", "orphan-apple", "orphan-loose"}
	if gotIDs := sessionIDs(got); !equalStrings(gotIDs, want) {
		t.Fatalf("order = %v, want %v", gotIDs, want)
	}
	// The orphan with no repo is the only ungrouped (trailing) row.
	if last := got[len(got)-1]; last.ID != "orphan-loose" || last.RepoIdentity != "" {
		t.Fatalf("trailing row = %+v, want ungrouped orphan-loose", last)
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestRenderRepoHeadersAppearPerSection(t *testing.T) {
	t.Parallel()

	rows := groupRowsByRepo([]SessionRow{
		{ID: "qm-a", Title: "alpha", Status: "active", SessionType: "standalone", RepoIdentity: "/a/.git", RepoName: "apple"},
		{ID: "qm-z", Title: "zeta", Status: "active", SessionType: "standalone", RepoIdentity: "/z/.git", RepoName: "zebra"},
		{ID: "qm-loose", Title: "loose", Status: "active", SessionType: "standalone"},
	})
	tm := newTestTracker(SessionInfo{ID: "qm-a"}, TrackerSnapshot{Sessions: rows}, &fakeActions{})

	view := ansi.Strip(tm.View())
	for _, want := range []string{"── apple ", "── zebra ", "── ungrouped "} {
		if !strings.Contains(view, want) {
			t.Fatalf("view missing repo header %q:\n%s", want, view)
		}
	}
	// Apple sorts before zebra, both before ungrouped.
	if idxApple, idxZebra, idxUng := strings.Index(view, "── apple "), strings.Index(view, "── zebra "), strings.Index(view, "── ungrouped "); !(idxApple < idxZebra && idxZebra < idxUng) {
		t.Fatalf("header order apple=%d zebra=%d ungrouped=%d, want ascending", idxApple, idxZebra, idxUng)
	}
}

func TestTrackerUpdateRepoColorEntersAndSeedsFromRepoColor(t *testing.T) {
	t.Parallel()

	tm := colorTracker(t, SessionRow{
		ID: "qm-a", Title: "a", Status: "active", SessionType: "standalone",
		RepoIdentity: "/repo/.git", RepoName: "repo", RepoColor: "green",
	}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('C'))
	if tm.mode != trackerModeColor {
		t.Fatalf("expected color mode, got %v", tm.mode)
	}
	if !tm.colorTargetRepo {
		t.Fatal("expected repo-color mode")
	}
	if tm.colorRepoIdentity != "/repo/.git" {
		t.Fatalf("repo identity = %q, want /repo/.git", tm.colorRepoIdentity)
	}
	if got := tm.previewColor(); got != "green" {
		t.Fatalf("seeded preview = %q, want green (current repo color)", got)
	}
}

func TestTrackerUpdateRepoColorWorksFromWorkerRow(t *testing.T) {
	t.Parallel()

	// c is disabled on workers, but C must work from any child row.
	tm := colorTracker(t, SessionRow{
		ID: "qm-w", Title: "w", Status: "active", SessionType: "worker", ParentID: "qm-m",
		RepoIdentity: "/repo/.git", RepoName: "repo",
	}, &fakeActions{})

	tm, _ = tm.Update(keyMsg('C'))
	if tm.mode != trackerModeColor || !tm.colorTargetRepo {
		t.Fatalf("C on a worker should enter repo-color mode, got mode=%v repo=%v", tm.mode, tm.colorTargetRepo)
	}
	if tm.colorRepoIdentity != "/repo/.git" {
		t.Fatalf("repo identity = %q, want /repo/.git", tm.colorRepoIdentity)
	}
}

func TestTrackerUpdateRepoColorCommitWritesRepoColor(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := colorTracker(t, SessionRow{
		ID: "qm-a", Status: "active", SessionType: "standalone",
		RepoIdentity: "/repo/.git", RepoName: "repo",
	}, actions)

	tm, _ = tm.Update(keyMsg('C'))                    // none
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRight}) // blue
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if tm.mode != trackerModeNormal {
		t.Fatalf("commit should return to normal, got %v", tm.mode)
	}
	if len(actions.setRepoColorCall) != 1 {
		t.Fatalf("expected one set-repo-color call, got %#v", actions.setRepoColorCall)
	}
	if actions.setRepoColorCall[0] != (setRepoColorCall{repoIdentity: "/repo/.git", color: "blue"}) {
		t.Fatalf("unexpected repo-color call: %#v", actions.setRepoColorCall[0])
	}
	// No session color was written.
	if len(actions.setColorCalls) != 0 {
		t.Fatalf("repo-color commit must not write a session color, got %#v", actions.setColorCalls)
	}
}

func TestTrackerUpdateRepoColorOnUngroupedRowIsNoOp(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := colorTracker(t, SessionRow{ID: "qm-a", Status: "active", SessionType: "standalone"}, actions)

	tm, _ = tm.Update(keyMsg('C'))
	if tm.mode != trackerModeNormal {
		t.Fatalf("C on a non-repo session should stay normal, got %v", tm.mode)
	}
	if tm.lastErr == nil {
		t.Fatal("expected an error explaining the session is not in a git repo")
	}
}

// --- end-to-end fetcher: fixtures built by hand, no git binary ---

func mkGitDir(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
}

func mkWorktreeFixture(t *testing.T, mainRoot, wtRoot, name string) {
	t.Helper()
	mkGitDir(t, mainRoot)
	meta := filepath.Join(mainRoot, ".git", "worktrees", name)
	if err := os.MkdirAll(meta, 0o755); err != nil {
		t.Fatalf("mkdir worktree meta: %v", err)
	}
	if err := os.WriteFile(filepath.Join(meta, "commondir"), []byte("../..\n"), 0o644); err != nil {
		t.Fatalf("write commondir: %v", err)
	}
	if err := os.MkdirAll(wtRoot, 0o755); err != nil {
		t.Fatalf("mkdir worktree root: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wtRoot, ".git"), []byte("gitdir: "+meta+"\n"), 0o644); err != nil {
		t.Fatalf("write worktree .git: %v", err)
	}
}

func TestLiveSessionFetcherGroupsReposFoldsWorktreesAndUngrouped(t *testing.T) {
	setTestStateRoot(t)

	tmp := t.TempDir()
	proj := filepath.Join(tmp, "proj")
	projWT := filepath.Join(tmp, "proj-feature")
	loose := filepath.Join(tmp, "loose")
	mkWorktreeFixture(t, proj, projWT, "feature")
	if err := os.MkdirAll(loose, 0o755); err != nil {
		t.Fatalf("mkdir loose: %v", err)
	}

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	mustCreate(t, store, state.Manifest{SessionID: "qm-master", SessionType: "master", Cwd: proj, Workers: []string{"qm-worker"}})
	worker := state.Manifest{SessionID: "qm-worker", Cwd: projWT}
	worker.SetExtra("parent_session", "qm-master")
	mustCreate(t, store, worker)
	mustCreate(t, store, state.Manifest{SessionID: "qm-loose", Cwd: loose})

	// Color the repo green (no session ever overrode it).
	projIdentity := mustIdentity(t, proj)
	if err := state.NewRepoColorStore(store.Root()).Set(projIdentity, "green"); err != nil {
		t.Fatalf("set repo color: %v", err)
	}

	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{
		"qm-master": true, "qm-worker": true, "qm-loose": true,
	}))
	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-master"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}

	rows := map[string]SessionRow{}
	for _, row := range snapshot.Sessions {
		rows[row.ID] = row
	}

	// Worktree folds onto the main repo; loose stays ungrouped.
	if rows["qm-worker"].RepoIdentity != projIdentity {
		t.Fatalf("worker repo = %q, want folded onto main repo %q", rows["qm-worker"].RepoIdentity, projIdentity)
	}
	if rows["qm-master"].RepoIdentity != projIdentity {
		t.Fatalf("master repo = %q, want %q", rows["qm-master"].RepoIdentity, projIdentity)
	}
	if rows["qm-loose"].RepoIdentity != "" {
		t.Fatalf("loose repo = %q, want ungrouped (empty)", rows["qm-loose"].RepoIdentity)
	}

	// Repo color resolves to the effective color and cascades to the worker.
	if rows["qm-master"].DisplayColor != "green" {
		t.Fatalf("master effective color = %q, want green (repo)", rows["qm-master"].DisplayColor)
	}
	if rows["qm-worker"].DisplayColor != "green" {
		t.Fatalf("worker effective color = %q, want inherited green", rows["qm-worker"].DisplayColor)
	}

	// Sectioned: the proj tree groups together, ahead of the ungrouped row.
	if ids := sessionIDs(snapshot.Sessions); !equalStrings(ids, []string{"qm-master", "qm-worker", "qm-loose"}) {
		t.Fatalf("session order = %v, want proj tree then ungrouped", ids)
	}
}

func TestLiveSessionFetcherSessionColorBeatsOlderRepoColor(t *testing.T) {
	setTestStateRoot(t)

	tmp := t.TempDir()
	proj := filepath.Join(tmp, "proj")
	mkGitDir(t, proj)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	// The session's own blue is stamped in the future, so it must beat any
	// repo color set "now".
	future := "2999-01-01T00:00:00Z"
	mustCreate(t, store, state.Manifest{
		SessionID:   "qm-a",
		SessionType: "standalone",
		Cwd:         proj,
		Display:     &state.DisplayMetadata{Color: "blue", ColorChangedAt: future},
	})

	projIdentity := mustIdentity(t, proj)
	if err := state.NewRepoColorStore(store.Root()).Set(projIdentity, "green"); err != nil {
		t.Fatalf("set repo color: %v", err)
	}

	client := tmux.NewClient(runnerWithLiveSessions(map[string]bool{"qm-a": true}))
	snapshot, err := NewLiveSessionFetcher(client, store)(SessionInfo{ID: "qm-a"})
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if got := snapshot.Sessions[0].DisplayColor; got != "blue" {
		t.Fatalf("effective color = %q, want blue (own change newer than repo)", got)
	}
	// The header still reflects the repo's own color, independent of the override.
	if got := snapshot.Sessions[0].RepoColor; got != "green" {
		t.Fatalf("repo color = %q, want green (header shows repo color)", got)
	}
}

func mustCreate(t *testing.T, store *state.Store, m state.Manifest) {
	t.Helper()
	if err := store.Create(m); err != nil {
		t.Fatalf("create %s: %v", m.SessionID, err)
	}
}

func mustIdentity(t *testing.T, path string) string {
	t.Helper()
	r, ok := repo.Resolve(path)
	if !ok {
		t.Fatalf("resolve %q: not a repo", path)
	}
	return r.Identity
}
