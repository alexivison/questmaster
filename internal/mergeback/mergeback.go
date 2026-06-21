package mergeback

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	StatusNoop     = "noop"
	StatusMerged   = "merged"
	StatusConflict = "conflict"
	StatusError    = "error"
)

// Result is the persisted and mutation-visible outcome of a merge-back attempt.
type Result struct {
	Status       string   `json:"status"`
	QuestID      string   `json:"quest_id,omitempty"`
	WorkerID     string   `json:"worker_id,omitempty"`
	MasterID     string   `json:"master_id,omitempty"`
	SourceBranch string   `json:"source_branch,omitempty"`
	TargetBranch string   `json:"target_branch,omitempty"`
	MergeBase    string   `json:"merge_base,omitempty"`
	Conflicts    []string `json:"conflicts,omitempty"`
	Message      string   `json:"message,omitempty"`
}

// ForQuest merges the first attached worker session's branch into its master.
// It never returns an error because quest status changes must not roll back.
func ForQuest(ctx context.Context, store *state.Store, questID string) Result {
	if store == nil {
		store = state.OpenStore(state.StateRoot())
	}
	ids, err := state.SessionsForQuest(questID)
	if err != nil {
		return Result{Status: StatusError, QuestID: questID, Message: err.Error()}
	}
	for _, id := range ids {
		m, err := store.Read(id)
		if err != nil || m.ExtraString("parent_session") == "" {
			continue
		}
		return ForWorker(ctx, store, id, questID)
	}
	return Result{Status: StatusNoop, QuestID: questID, Message: "no attached worker session"}
}

// ForWorker conservatively merges a worker branch into its master branch.
func ForWorker(ctx context.Context, store *state.Store, workerID, questID string) Result {
	result := Result{Status: StatusError, QuestID: questID, WorkerID: workerID}
	worker, err := store.Read(workerID)
	if err != nil {
		result.Message = "read worker manifest: " + err.Error()
		logResult(result)
		return result
	}
	masterID := worker.ExtraString("parent_session")
	result.MasterID = masterID
	if masterID == "" {
		result.Status = StatusNoop
		result.Message = "session is not a worker"
		logResult(result)
		return result
	}
	master, err := store.Read(masterID)
	if err != nil {
		result.Message = "read master manifest: " + err.Error()
		logResult(result)
		return result
	}

	if err := validateWorktrees(worker.Cwd, master.Cwd); err != nil {
		result.Message = err.Error()
		logResult(result)
		return result
	}
	if err := requireSameRepo(ctx, worker.Cwd, master.Cwd); err != nil {
		result.Message = err.Error()
		logResult(result)
		return result
	}

	sourceBranch, err := currentBranch(ctx, worker.Cwd)
	if err != nil {
		result.Message = "resolve worker branch: " + err.Error()
		logResult(result)
		return result
	}
	targetBranch, err := currentBranch(ctx, master.Cwd)
	if err != nil {
		result.Message = "resolve master branch: " + err.Error()
		logResult(result)
		return result
	}
	result.SourceBranch = sourceBranch
	result.TargetBranch = targetBranch

	if dirty, err := gitTrim(ctx, worker.Cwd, "status", "--porcelain"); err != nil {
		result.Message = "check source worktree status: " + err.Error()
		logResult(result)
		return result
	} else if dirty != "" {
		result.Message = "source worktree has uncommitted changes"
		logResult(result)
		return result
	}

	unique, err := sourceUniqueCommitCount(ctx, master.Cwd, targetBranch, sourceBranch)
	if err != nil {
		result.Message = "count source commits: " + err.Error()
		logResult(result)
		return result
	}
	if unique == 0 {
		result.Status = StatusNoop
		result.Message = "source branch has no commits absent from target"
		logResult(result)
		return result
	}
	base, err := gitTrim(ctx, master.Cwd, "merge-base", targetBranch, sourceBranch)
	if err != nil {
		result.Message = "find merge base: " + err.Error()
		logResult(result)
		return result
	}
	result.MergeBase = base

	if dirty, err := gitTrim(ctx, master.Cwd, "status", "--porcelain"); err != nil {
		result.Message = "check target worktree status: " + err.Error()
		logResult(result)
		return result
	} else if dirty != "" {
		result.Message = "target worktree has uncommitted changes"
		logResult(result)
		return result
	}

	if out, err := gitCombined(ctx, master.Cwd, "merge-tree", "--write-tree", "--messages", "--name-only", "--merge-base", base, targetBranch, sourceBranch); err != nil {
		conflicts, isConflict := parseMergeTreeConflictOutput(out)
		if !isConflict {
			result.Message = "merge-tree preflight failed: " + commandDetail(err, out)
		} else {
			result.Conflicts = conflicts
			result.Status = StatusConflict
			result.Message = "merge conflicts detected before mutating target"
		}
		logResult(result)
		return result
	}

	out, err := gitCombined(ctx, master.Cwd, "merge", "--no-edit", sourceBranch)
	if err != nil {
		_, _ = gitCombined(ctx, master.Cwd, "merge", "--abort")
		result.Message = "merge failed after clean preflight: " + commandDetail(err, out)
		logResult(result)
		return result
	}
	result.Status = StatusMerged
	result.Message = strings.TrimSpace(out)
	logResult(result)
	return result
}

func validateWorktrees(workerCwd, masterCwd string) error {
	if strings.TrimSpace(workerCwd) == "" {
		return fmt.Errorf("worker manifest has no cwd")
	}
	if strings.TrimSpace(masterCwd) == "" {
		return fmt.Errorf("master manifest has no cwd")
	}
	return nil
}

func requireSameRepo(ctx context.Context, workerCwd, masterCwd string) error {
	workerGit, err := commonGitDir(ctx, workerCwd)
	if err != nil {
		return fmt.Errorf("resolve worker git dir: %w", err)
	}
	masterGit, err := commonGitDir(ctx, masterCwd)
	if err != nil {
		return fmt.Errorf("resolve master git dir: %w", err)
	}
	if workerGit != masterGit {
		return fmt.Errorf("worker and master are not in the same git repository")
	}
	return nil
}

func commonGitDir(ctx context.Context, cwd string) (string, error) {
	out, err := gitTrim(ctx, cwd, "rev-parse", "--git-common-dir")
	if err != nil {
		return "", err
	}
	if !filepath.IsAbs(out) {
		out = filepath.Join(cwd, out)
	}
	if resolved, err := filepath.EvalSymlinks(out); err == nil {
		out = resolved
	}
	return filepath.Clean(out), nil
}

func currentBranch(ctx context.Context, cwd string) (string, error) {
	branch, err := gitTrim(ctx, cwd, "branch", "--show-current")
	if err != nil {
		return "", err
	}
	if branch == "" {
		return "", fmt.Errorf("worktree is detached")
	}
	return branch, nil
}

func sourceUniqueCommitCount(ctx context.Context, cwd, targetBranch, sourceBranch string) (int, error) {
	out, err := gitTrim(ctx, cwd, "rev-list", "--count", targetBranch+".."+sourceBranch)
	if err != nil {
		return 0, err
	}
	n, err := strconv.Atoi(out)
	if err != nil {
		return 0, fmt.Errorf("parse rev-list count %q: %w", out, err)
	}
	return n, nil
}

func parseMergeTreeConflictOutput(out string) ([]string, bool) {
	lines := strings.Split(out, "\n")
	if len(lines) == 0 || !isGitObjectID(strings.TrimSpace(lines[0])) {
		return nil, false
	}
	var conflicts []string
	for _, line := range lines[1:] {
		line = strings.TrimSpace(line)
		if line == "" {
			break
		}
		conflicts = append(conflicts, line)
	}
	return conflicts, true
}

func isGitObjectID(value string) bool {
	switch len(value) {
	case 40, 64:
	default:
		return false
	}
	for _, r := range value {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F') {
			continue
		}
		return false
	}
	return true
}

func gitTrim(ctx context.Context, cwd string, args ...string) (string, error) {
	out, err := gitCombined(ctx, cwd, args...)
	if err != nil {
		return "", fmt.Errorf("%s: %s", strings.Join(args, " "), commandDetail(err, out))
	}
	return strings.TrimSpace(out), nil
}

func gitCombined(ctx context.Context, cwd string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = cwd
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.String(), err
}

func commandDetail(err error, out string) string {
	detail := strings.TrimSpace(out)
	if detail == "" {
		return err.Error()
	}
	return err.Error() + ": " + boundedMessage(detail)
}

func boundedMessage(message string) string {
	const max = 2000
	runes := []rune(strings.TrimSpace(message))
	if len(runes) <= max {
		return string(runes)
	}
	return string(runes[:max]) + "\n[... output truncated ...]"
}

func logResult(result Result) {
	if result.WorkerID == "" || !state.IsValidSessionID(result.WorkerID) {
		return
	}
	fields := map[string]interface{}{
		"quest_id":      result.QuestID,
		"worker_id":     result.WorkerID,
		"master_id":     result.MasterID,
		"source_branch": result.SourceBranch,
		"target_branch": result.TargetBranch,
		"merge_base":    result.MergeBase,
		"conflicts":     result.Conflicts,
		"message":       result.Message,
		"merge_status":  result.Status,
	}
	ev := state.StateEvent{Action: "merge_back", State: result.Status, Fields: fields}
	if err := state.AppendStateEvent(result.WorkerID, ev); err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: log merge-back for %s: %v\n", result.WorkerID, err)
	}
	if err := state.AppendLifecycleEvent(result.WorkerID, ev); err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: log lifecycle merge-back for %s: %v\n", result.WorkerID, err)
	}
}
