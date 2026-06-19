//go:build linux || darwin

package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestWorkerSetupHookRunsBeforeLaunchWithEnv(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)
	t.Setenv("QUESTMASTER_STATE", stateRoot)

	svc, runner := setupService(t)
	svc.Now = func() int64 { return 200 }
	masterCwd := t.TempDir()
	workerCwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "master", masterCwd, "master")

	hookLog := filepath.Join(t.TempDir(), "setup.env")
	writeExecutableHook(t, workerCwd, "setup", `#!/bin/sh
printf '%s|%s|%s|%s|%s\n' "$QM_SESSION_ID" "$QM_QUEST_ID" "$QM_WORKTREE" "$QM_MASTER_SESSION_ID" "$QUESTMASTER_STATE_ROOT" > "$HOOK_LOG"
`)
	t.Setenv("HOOK_LOG", hookLog)

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:      workerCwd,
		MasterID: "qm-master",
		QuestID:  "DEMO-1",
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !runner.sessions[result.SessionID] {
		t.Fatalf("worker session was not launched")
	}

	raw, err := os.ReadFile(hookLog)
	if err != nil {
		t.Fatalf("read setup hook log: %v", err)
	}
	want := result.SessionID + "|DEMO-1|" + workerCwd + "|qm-master|" + stateRoot + "\n"
	if string(raw) != want {
		t.Fatalf("setup env = %q, want %q", raw, want)
	}
	assertStateLogContains(t, stateRoot, result.SessionID, `"action":"worktree_setup"`, `"state":"pass"`)
}

func TestWorkerSetupHookAbsentIsNoop(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)
	t.Setenv("QUESTMASTER_STATE", stateRoot)

	svc, runner := setupService(t)
	svc.Now = func() int64 { return 201 }
	createTestManifest(t, svc.Store, "qm-master", "master", t.TempDir(), "master")

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:      t.TempDir(),
		MasterID: "qm-master",
	})
	if err != nil {
		t.Fatalf("Start without setup hook: %v", err)
	}
	if !runner.sessions[result.SessionID] {
		t.Fatalf("worker session was not launched")
	}
}

func TestWorkerSetupHookFailureIsLoggedAndSurfaced(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)
	t.Setenv("QUESTMASTER_STATE", stateRoot)

	svc, runner := setupService(t)
	svc.Now = func() int64 { return 202 }
	workerCwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "master", t.TempDir(), "master")
	writeExecutableHook(t, workerCwd, "setup", `#!/bin/sh
echo setup failed loudly
exit 7
`)

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:      workerCwd,
		MasterID: "qm-master",
		QuestID:  "DEMO-1",
	})
	if err == nil {
		t.Fatalf("Start error = nil, want setup failure")
	}
	if !strings.Contains(err.Error(), "setup hook failed") || !strings.Contains(err.Error(), "setup failed loudly") {
		t.Fatalf("Start error %q does not surface setup failure output", err)
	}
	if runner.sessions[result.SessionID] || runner.sessions["qm-202"] {
		t.Fatalf("tmux session should not be launched after setup failure")
	}
	assertLifecycleLogContains(t, stateRoot, `"action":"worktree_setup"`, `"state":"fail"`, `"session_id":"qm-202"`, "setup failed loudly")
}

func TestWorkerTeardownHookRunsOnDeregisterWithEnv(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)
	t.Setenv("QUESTMASTER_STATE", stateRoot)

	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	workerCwd := t.TempDir()
	master := "qm-master"
	worker := "qm-worker"
	if err := store.Create(state.Manifest{SessionID: master, SessionType: "master", Workers: []string{worker}, Cwd: t.TempDir()}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	m := state.Manifest{SessionID: worker, Cwd: workerCwd}
	m.SetExtra("parent_session", master)
	if err := store.Create(m); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := state.StampQuest(worker, "DEMO-1"); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	hookLog := filepath.Join(t.TempDir(), "teardown.env")
	writeExecutableHook(t, workerCwd, "teardown", `#!/bin/sh
printf '%s|%s|%s|%s|%s\n' "$QM_SESSION_ID" "$QM_QUEST_ID" "$QM_WORKTREE" "$QM_MASTER_SESSION_ID" "$QUESTMASTER_STATE_ROOT" > "$HOOK_LOG"
`)
	t.Setenv("HOOK_LOG", hookLog)

	svc := &Service{Store: store, Client: nil}
	if err := svc.Deregister(worker); err != nil {
		t.Fatalf("Deregister: %v", err)
	}

	raw, err := os.ReadFile(hookLog)
	if err != nil {
		t.Fatalf("read teardown hook log: %v", err)
	}
	want := worker + "|DEMO-1|" + workerCwd + "|" + master + "|" + stateRoot + "\n"
	if string(raw) != want {
		t.Fatalf("teardown env = %q, want %q", raw, want)
	}
	if _, err := store.Read(worker); err == nil {
		t.Fatalf("worker manifest should be deleted")
	}
	assertLifecycleLogContains(t, stateRoot, `"action":"worktree_teardown"`, `"state":"pass"`, `"session_id":"qm-worker"`)
}

func writeExecutableHook(t *testing.T, worktree, name, body string) {
	t.Helper()
	dir := filepath.Join(worktree, ".questmaster")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir hook dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o755); err != nil {
		t.Fatalf("write %s hook: %v", name, err)
	}
}

func assertStateLogContains(t *testing.T, root, sessionID string, parts ...string) {
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

func assertLifecycleLogContains(t *testing.T, root string, parts ...string) {
	t.Helper()
	raw, err := os.ReadFile(state.LifecycleLogPath(root))
	if err != nil {
		t.Fatalf("read lifecycle log: %v", err)
	}
	body := string(raw)
	for _, part := range parts {
		if !strings.Contains(body, part) {
			t.Fatalf("lifecycle log missing %q:\n%s", part, body)
		}
	}
}
