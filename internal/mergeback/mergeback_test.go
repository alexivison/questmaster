package mergeback

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestParseMergeTreeConflictOutputRejectsHardErrors(t *testing.T) {
	out := "fatal: refusing to merge unrelated histories\nhint: use --allow-unrelated-histories if you want to merge anyway\n"
	conflicts, ok := parseMergeTreeConflictOutput(out)
	if ok {
		t.Fatalf("hard merge-tree error parsed as conflict: ok=%v conflicts=%v", ok, conflicts)
	}
	if len(conflicts) != 0 {
		t.Fatalf("hard merge-tree error conflicts = %v, want none", conflicts)
	}
}

func TestParseMergeTreeConflictOutputRequiresTreeSHA(t *testing.T) {
	sha := strings.Repeat("a", 40)
	conflicts, ok := parseMergeTreeConflictOutput(sha + "\ninternal/file.go\n\nAuto-merging internal/file.go\n")
	if !ok {
		t.Fatal("valid merge-tree conflict output was not recognized")
	}
	if len(conflicts) != 1 || conflicts[0] != "internal/file.go" {
		t.Fatalf("conflicts = %v, want [internal/file.go]", conflicts)
	}
}

func TestForWorkerBlocksDirtySourceWorktree(t *testing.T) {
	requireGit(t)

	root := t.TempDir()
	repo := filepath.Join(root, "repo")
	runGit(t, "", "init", repo)
	runGit(t, repo, "config", "user.email", "test@example.com")
	runGit(t, repo, "config", "user.name", "Test User")
	writeFile(t, filepath.Join(repo, "README.md"), "base\n")
	runGit(t, repo, "add", "README.md")
	runGit(t, repo, "commit", "-m", "base")
	runGit(t, repo, "branch", "-M", "main")

	workerDir := filepath.Join(root, "worker")
	runGit(t, repo, "worktree", "add", "-b", "worker", workerDir, "main")
	writeFile(t, filepath.Join(workerDir, "dirty.txt"), "uncommitted\n")

	stateRoot := filepath.Join(root, "state")
	t.Setenv(state.StateRootEnv, stateRoot)
	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	masterID := "qm-master-merge"
	workerID := "qm-worker-merge"
	if err := store.Create(state.Manifest{
		SessionID:   masterID,
		SessionType: "master",
		Cwd:         repo,
		Workers:     []string{workerID},
	}); err != nil {
		t.Fatalf("create master manifest: %v", err)
	}
	worker := state.Manifest{SessionID: workerID, Cwd: workerDir}
	worker.SetExtra("parent_session", masterID)
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}

	result := ForWorker(context.Background(), store, workerID, "DEMO-1")
	if result.Status != StatusError {
		t.Fatalf("status = %q, want %q; result=%+v", result.Status, StatusError, result)
	}
	if !strings.Contains(result.Message, "source worktree has uncommitted changes") {
		t.Fatalf("message = %q, want dirty source error", result.Message)
	}
}

func requireGit(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
}

func runGit(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	if dir != "" {
		cmd.Dir = dir
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
