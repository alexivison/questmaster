//go:build linux || darwin

package lifecycle

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

func TestSetStatusDoneMergeBackCleanMerge(t *testing.T) {
	env := newMergeBackFixture(t)
	git(t, env.workerCwd, "checkout", "-q", "worker")
	mustWrite(t, filepath.Join(env.workerCwd, "worker.txt"), "worker\n")
	git(t, env.workerCwd, "add", "worker.txt")
	git(t, env.workerCwd, "commit", "-q", "-m", "worker change")

	result, err := SetStatus(t.Context(), env.questStore, env.sessionStore, env.questID, quest.StatusDone)
	if err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	if result.Status != quest.StatusDone {
		t.Fatalf("status = %q, want done", result.Status)
	}
	if result.MergeBack == nil || result.MergeBack.Status != "merged" {
		t.Fatalf("merge_back = %#v, want merged", result.MergeBack)
	}
	if got := gitOut(t, env.masterCwd, "show", "master:worker.txt"); got != "worker\n" {
		t.Fatalf("master worker.txt = %q, want worker file", got)
	}
	assertLifecycleStateLogContains(t, env.stateRoot, env.workerID, `"action":"merge_back"`, `"state":"merged"`)
}

func TestSetStatusDoneMergeBackConflictLogsAndDoesNotMutateTarget(t *testing.T) {
	env := newMergeBackFixture(t)
	git(t, env.workerCwd, "checkout", "-q", "worker")
	mustWrite(t, filepath.Join(env.workerCwd, "shared.txt"), "worker\n")
	git(t, env.workerCwd, "commit", "-am", "worker edit", "-q")

	git(t, env.masterCwd, "checkout", "-q", "master")
	mustWrite(t, filepath.Join(env.masterCwd, "shared.txt"), "master\n")
	git(t, env.masterCwd, "commit", "-am", "master edit", "-q")
	before := gitOut(t, env.masterCwd, "rev-parse", "master")

	result, err := SetStatus(t.Context(), env.questStore, env.sessionStore, env.questID, quest.StatusDone)
	if err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	loaded, err := env.questStore.Load(env.questID)
	if err != nil {
		t.Fatalf("load quest: %v", err)
	}
	if loaded.Status != quest.StatusDone {
		t.Fatalf("quest status = %q, want done despite conflict", loaded.Status)
	}
	if result.MergeBack == nil || result.MergeBack.Status != "conflict" {
		t.Fatalf("merge_back = %#v, want conflict", result.MergeBack)
	}
	if !contains(result.MergeBack.Conflicts, "shared.txt") {
		t.Fatalf("conflicts = %v, want shared.txt", result.MergeBack.Conflicts)
	}
	after := gitOut(t, env.masterCwd, "rev-parse", "master")
	if after != before {
		t.Fatalf("master branch mutated on conflict: before %s after %s", before, after)
	}
	if got := gitOut(t, env.masterCwd, "status", "--porcelain"); got != "" {
		t.Fatalf("master worktree dirty after conflict preflight:\n%s", got)
	}
	if got := gitOut(t, env.masterCwd, "show", "master:shared.txt"); got != "master\n" {
		t.Fatalf("master shared.txt = %q, want original master content", got)
	}
	assertLifecycleStateLogContains(t, env.stateRoot, env.workerID, `"action":"merge_back"`, `"state":"conflict"`, "shared.txt")
}

func TestSetStatusDoneMergeBackNothingToMergeIsNoop(t *testing.T) {
	env := newMergeBackFixture(t)

	result, err := SetStatus(t.Context(), env.questStore, env.sessionStore, env.questID, quest.StatusDone)
	if err != nil {
		t.Fatalf("SetStatus: %v", err)
	}
	if result.MergeBack == nil || result.MergeBack.Status != "noop" {
		t.Fatalf("merge_back = %#v, want noop", result.MergeBack)
	}
	assertLifecycleStateLogContains(t, env.stateRoot, env.workerID, `"action":"merge_back"`, `"state":"noop"`)
}

type mergeBackFixture struct {
	stateRoot    string
	masterCwd    string
	workerCwd    string
	questID      string
	workerID     string
	questStore   *quest.FileStore
	sessionStore *state.Store
}

func newMergeBackFixture(t *testing.T) mergeBackFixture {
	t.Helper()
	tmp := t.TempDir()
	stateRoot := filepath.Join(tmp, "state")
	t.Setenv(state.StateRootEnv, stateRoot)
	t.Setenv("QUESTMASTER_STATE", stateRoot)
	t.Setenv(quest.HomeEnv, filepath.Join(tmp, "home"))

	repoRoot := filepath.Join(tmp, "repo")
	if err := os.MkdirAll(repoRoot, 0o755); err != nil {
		t.Fatalf("mkdir repo: %v", err)
	}
	git(t, repoRoot, "init", "-q", "--initial-branch", "master")
	git(t, repoRoot, "config", "user.email", "test@example.com")
	git(t, repoRoot, "config", "user.name", "Questmaster Test")
	mustWrite(t, filepath.Join(repoRoot, "shared.txt"), "base\n")
	git(t, repoRoot, "add", "shared.txt")
	git(t, repoRoot, "commit", "-q", "-m", "base")

	workerCwd := filepath.Join(tmp, "worker")
	git(t, repoRoot, "worktree", "add", "-q", "-b", "worker", workerCwd, "master")

	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("new state store: %v", err)
	}
	masterID := "qm-master"
	workerID := "qm-worker"
	if err := store.Create(state.Manifest{SessionID: masterID, SessionType: "master", Cwd: repoRoot, Workers: []string{workerID}}); err != nil {
		t.Fatalf("create master manifest: %v", err)
	}
	worker := state.Manifest{SessionID: workerID, Cwd: workerCwd}
	worker.SetExtra("parent_session", masterID)
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}

	questID := "DEMO-1"
	if err := state.StampQuest(workerID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}
	questStore := quest.DefaultStore()
	if err := questStore.Save(&quest.Quest{ID: questID, Title: "Demo", Summary: "s", Status: quest.StatusActive}); err != nil {
		t.Fatalf("save quest: %v", err)
	}

	return mergeBackFixture{
		stateRoot:    stateRoot,
		masterCwd:    repoRoot,
		workerCwd:    workerCwd,
		questID:      questID,
		workerID:     workerID,
		questStore:   questStore,
		sessionStore: store,
	}
}

func git(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s in %s: %v\n%s", strings.Join(args, " "), dir, err, out)
	}
}

func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s in %s: %v\n%s", strings.Join(args, " "), dir, err, out)
	}
	return string(out)
}

func mustWrite(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func contains(values []string, want string) bool {
	for _, v := range values {
		if v == want {
			return true
		}
	}
	return false
}

func assertLifecycleStateLogContains(t *testing.T, root, sessionID string, parts ...string) {
	t.Helper()
	raw, err := os.ReadFile(state.SessionStateLogPath(root, sessionID))
	if err != nil {
		t.Fatalf("read state log for %s: %v", sessionID, err)
	}
	body := string(raw)
	for _, part := range parts {
		if !strings.Contains(body, part) {
			t.Fatalf("state log for %s missing %q:\n%s", sessionID, part, body)
		}
	}
}
