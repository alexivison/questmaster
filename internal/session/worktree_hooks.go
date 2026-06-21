package session

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/textutil"
)

const (
	worktreeHookDir      = ".questmaster"
	worktreeSetupHook    = "setup"
	worktreeTeardownHook = "teardown"
)

var worktreeTeardownHookTimeout = 5 * time.Second

func (s *Service) runWorktreeSetupHook(ctx context.Context, sessionID, questID string) error {
	m, err := s.Store.Read(sessionID)
	if err != nil {
		return err
	}
	if !isWorkerManifest(m) {
		return nil
	}
	result, err := runWorktreeHook(ctx, m, worktreeSetupHook, questID)
	if !result.Configured {
		return nil
	}
	logWorktreeHookResult(sessionID, result)
	if err != nil {
		return fmt.Errorf("setup hook failed for %s: %w", sessionID, err)
	}
	return nil
}

func (s *Service) runWorktreeTeardownHook(ctx context.Context, sessionID string) {
	m, err := s.Store.Read(sessionID)
	if err != nil || !isWorkerManifest(m) {
		return
	}
	questID, _ := state.QuestIDForSession(sessionID)
	hookCtx, cancel := context.WithTimeout(ctx, worktreeTeardownHookTimeout)
	defer cancel()
	result, err := runWorktreeHook(hookCtx, m, worktreeTeardownHook, questID)
	if hookCtx.Err() == context.DeadlineExceeded {
		err = fmt.Errorf("teardown hook timed out after %s", worktreeTeardownHookTimeout)
		result.Err = err
	}
	if !result.Configured {
		return
	}
	logWorktreeHookResult(sessionID, result)
	if err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: teardown hook failed for %s: %v\n", sessionID, err)
	}
}

func isWorkerManifest(m state.Manifest) bool {
	return m.ExtraString("parent_session") != ""
}

type worktreeHookResult struct {
	Name            string
	Action          string
	Configured      bool
	Path            string
	Worktree        string
	QuestID         string
	MasterSessionID string
	Output          string
	Err             error
}

func runWorktreeHook(ctx context.Context, m state.Manifest, name, questID string) (worktreeHookResult, error) {
	result := worktreeHookResult{
		Name:            name,
		Action:          "worktree_" + name,
		Worktree:        m.Cwd,
		QuestID:         questID,
		MasterSessionID: m.ExtraString("parent_session"),
	}
	if strings.TrimSpace(m.Cwd) == "" {
		return result, nil
	}
	path := filepath.Join(m.Cwd, worktreeHookDir, name)
	result.Path = path
	ok, err := executableHook(path)
	if err != nil {
		result.Configured = true
		result.Err = err
		return result, err
	}
	if !ok {
		return result, nil
	}
	result.Configured = true

	cmd := exec.CommandContext(ctx, path)
	cmd.Dir = m.Cwd
	cmd.Env = worktreeHookEnv(os.Environ(), m, questID)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err = cmd.Run()
	result.Output = strings.TrimSpace(out.String())
	result.Err = err
	if err != nil {
		return result, hookRunError(name, err, result.Output)
	}
	return result, nil
}

func executableHook(path string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	if info.IsDir() || info.Mode().Perm()&0o111 == 0 {
		return false, nil
	}
	return true, nil
}

func worktreeHookEnv(base []string, m state.Manifest, questID string) []string {
	env := append([]string{}, base...)
	env = append(env,
		"QM_SESSION_ID="+m.SessionID,
		"QM_QUEST_ID="+questID,
		"QM_WORKTREE="+m.Cwd,
		"QM_MASTER_SESSION_ID="+m.ExtraString("parent_session"),
		state.SessionEnv+"="+m.SessionID,
	)
	if root := state.StateRoot(); root != "" {
		env = append(env, state.StateRootEnv+"="+root, "QUESTMASTER_STATE="+root)
	}
	return env
}

func hookRunError(name string, err error, output string) error {
	if output == "" {
		return fmt.Errorf("%s hook: %w", name, err)
	}
	return fmt.Errorf("%s hook: %w: %s", name, err, textutil.BoundedOutput(output))
}

func logWorktreeHookResult(sessionID string, result worktreeHookResult) {
	stateValue := "pass"
	if result.Err != nil {
		stateValue = "fail"
	}
	fields := map[string]interface{}{
		"hook":              result.Name,
		"path":              result.Path,
		"worktree":          result.Worktree,
		"quest_id":          result.QuestID,
		"master_session_id": result.MasterSessionID,
	}
	if result.Output != "" {
		fields["output"] = result.Output
	}
	if result.Err != nil {
		fields["error"] = result.Err.Error()
	}
	ev := state.StateEvent{
		Action: result.Action,
		State:  stateValue,
		Fields: fields,
	}
	if err := state.AppendStateEvent(sessionID, ev); err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: log %s for %s: %v\n", result.Action, sessionID, err)
	}
	if err := state.AppendLifecycleEvent(sessionID, ev); err != nil {
		fmt.Fprintf(os.Stderr, "questmaster: warning: log lifecycle %s for %s: %v\n", result.Action, sessionID, err)
	}
}
