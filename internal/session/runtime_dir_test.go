//go:build linux || darwin

package session

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

// uniqueSessionClock returns a Now whose session ID no other test uses, so a
// test can assert that nothing appeared at that ID's legacy /tmp path.
func uniqueSessionClock() func() int64 {
	now := time.Now().UnixNano()
	return func() int64 { return now }
}

func hookCommand(t *testing.T, runner *mockRunner) string {
	t.Helper()
	for _, c := range runner.calls {
		if len(c.args) >= 3 && c.args[0] == "set-hook" {
			return c.args[len(c.args)-1]
		}
	}
	t.Fatal("set-hook call not found")
	return ""
}

func assertPerm(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %04o, want %04o", path, got, want)
	}
}

func assertAbsent(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("%s exists (err=%v); want nothing there", path, err)
	}
}

// A new session's runtime files live in a private directory under the state
// root, recorded in its manifest, and every producer uses that path. Nothing
// is created at /tmp/<id>.
func TestStartGivesANewSessionAPrivateRuntimeDir(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:       t.TempDir(),
		ResumeIDs: map[string]string{"claude": "claude-resume"},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	id := result.SessionID
	root := svc.Store.Root()
	want := filepath.Join(root, "runtime", id)
	if result.RuntimeDir != want {
		t.Fatalf("RuntimeDir = %q, want %q", result.RuntimeDir, want)
	}
	m, err := svc.Store.Read(id)
	if err != nil {
		t.Fatal(err)
	}
	if m.RuntimeDir != want {
		t.Fatalf("manifest runtime_dir = %q, want %q", m.RuntimeDir, want)
	}

	// Open question 15: the state root, the runtime parent and the session's
	// directory are owner-only, and so is every file in it. Lock files sit
	// beside the manifests in the root.
	assertPerm(t, root, 0o700)
	assertPerm(t, filepath.Join(root, "runtime"), 0o700)
	assertPerm(t, want, 0o700)
	for _, name := range []string{"session-name", "claude-session-id"} {
		assertPerm(t, filepath.Join(want, name), 0o600)
	}
	for _, name := range []string{id + ".json.lock", id + ".lifecycle.lock"} {
		if _, err := os.Stat(filepath.Join(root, name)); err != nil {
			t.Fatalf("lock file %s not in the state root: %v", name, err)
		}
	}

	if got := runner.envVars[id+":"+state.RuntimeDirEnv]; got != want {
		t.Fatalf("%s = %q, want %q", state.RuntimeDirEnv, got, want)
	}
	if runner.hasCall("set-hook") {
		t.Fatal("per-session cleanup hook installed")
	}
	assertAbsent(t, filepath.Join(want, "cleanup.sh"))
	assertAbsent(t, filepath.Join("/tmp", id))
}

// A symlink planted where the runtime directory goes makes Start fail before
// anything is written through it, and the start is rolled back.
func TestStartRefusesASymlinkAtTheRuntimeDir(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 1700000101 }
	id := state.NewSessionID(1700000101)
	target := t.TempDir()
	if err := os.Chmod(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(svc.Store.Root(), "runtime"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(svc.Store.Root(), "runtime", id)); err != nil {
		t.Fatal(err)
	}

	_, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Shell: true})
	if err == nil {
		t.Fatal("Start followed a symlink at the runtime dir")
	}
	entries, readErr := os.ReadDir(target)
	if readErr != nil || len(entries) != 0 {
		t.Fatalf("symlink target changed: %v, %v", entries, readErr)
	}
	assertPerm(t, target, 0o755)
	if runner.hasCall("new-session") {
		t.Fatal("Start created a tmux session after refusing the runtime dir")
	}
	if _, err := svc.Store.Read(id); err == nil {
		t.Fatal("manifest kept after a refused start")
	}
}

// legacyFixture is a session started before runtime_dir was recorded: its
// manifest has no field and its files sit in /tmp/<id>.
func legacyFixture(t *testing.T, svc *Service, prefix string) (string, string) {
	t.Helper()
	id := uniqueRuntimeSessionID(t, prefix)
	dir := filepath.Join("/tmp", id)
	if err := os.WriteFile(filepath.Join(dir, "session-name"), []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	createTestManifest(t, svc.Store, id, "legacy", t.TempDir(), "")
	if m, err := svc.Store.Read(id); err != nil || m.RuntimeDir != "" {
		t.Fatalf("legacy fixture has runtime_dir %q (%v)", m.RuntimeDir, err)
	}
	return id, dir
}

// Continue on a live legacy session reattaches at its /tmp path: it hands
// that path to the session and creates nothing, there or under the state root.
func TestContinueLiveLegacySessionKeepsItsTmpPath(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	id, dir := legacyFixture(t, svc, "qm-legacy-live")
	runner.sessions[id] = true

	result, err := svc.Continue(t.Context(), id)
	if err != nil {
		t.Fatalf("Continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected a reattach")
	}
	if got := runner.envVars[id+":"+state.RuntimeDirEnv]; got != dir {
		t.Fatalf("%s = %q, want the legacy %q", state.RuntimeDirEnv, got, dir)
	}
	if data, _ := os.ReadFile(filepath.Join(dir, "session-name")); string(data) != "old\n" {
		t.Fatalf("legacy runtime dir rewritten: session-name = %q", data)
	}
	assertAbsent(t, filepath.Join(svc.Store.Root(), "runtime"))
	if m, _ := svc.Store.Read(id); m.RuntimeDir != "" {
		t.Fatalf("live legacy session migrated to %q", m.RuntimeDir)
	}
}

// A live legacy session whose /tmp directory is gone is not given a new one
// there: Questmaster never creates a /tmp/<id> path.
func TestContinueLiveLegacySessionDoesNotRecreateTmp(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	id, dir := legacyFixture(t, svc, "qm-legacy-gone")
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	runner.sessions[id] = true

	if _, err := svc.Continue(t.Context(), id); err != nil {
		t.Fatalf("Continue: %v", err)
	}
	assertAbsent(t, dir)
	assertAbsent(t, filepath.Join(svc.Store.Root(), "runtime"))
}

// Deleting a legacy session removes its /tmp directory and creates nothing.
func TestDeleteLegacySessionRemovesItsTmpPath(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	id, dir := legacyFixture(t, svc, "qm-legacy-delete")

	if _, err := svc.Delete(t.Context(), id); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	assertAbsent(t, dir)
	assertAbsent(t, filepath.Join(svc.Store.Root(), "runtime"))
}

// A stopped legacy session has nothing running at its /tmp path, so Continue
// relaunches it with a private directory, records it, and leaves /tmp alone.
func TestContinueStoppedLegacySessionMovesToAPrivateDir(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	id, dir := legacyFixture(t, svc, "qm-legacy-stopped")
	if err := os.RemoveAll(dir); err != nil { // the session-closed hook removed it
		t.Fatal(err)
	}

	if _, err := svc.Continue(t.Context(), id); err != nil {
		t.Fatalf("Continue: %v", err)
	}
	want := filepath.Join(svc.Store.Root(), "runtime", id)
	m, err := svc.Store.Read(id)
	if err != nil {
		t.Fatal(err)
	}
	if m.RuntimeDir != want {
		t.Fatalf("runtime_dir after relaunch = %q, want %q", m.RuntimeDir, want)
	}
	assertPerm(t, want, 0o700)
	assertAbsent(t, filepath.Join(want, "cleanup.sh"))
	if got := runner.envVars[id+":"+state.RuntimeDirEnv]; got != want {
		t.Fatalf("%s = %q, want %q", state.RuntimeDirEnv, got, want)
	}
	assertAbsent(t, dir)
}

// Continue on a live session reuses its recorded directory, recreating it when
// it has gone missing, and creates nothing at /tmp/<id>.
func TestContinueLiveSessionReusesItsRecordedDir(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Shell: true})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := os.RemoveAll(result.RuntimeDir); err != nil {
		t.Fatal(err)
	}
	delete(runner.envVars, result.SessionID+":"+state.RuntimeDirEnv)

	if _, err := svc.Continue(t.Context(), result.SessionID); err != nil {
		t.Fatalf("Continue: %v", err)
	}
	assertPerm(t, result.RuntimeDir, 0o700)
	if data, _ := os.ReadFile(filepath.Join(result.RuntimeDir, "session-name")); string(data) != result.SessionID+"\n" {
		t.Fatalf("session-name = %q", data)
	}
	if got := runner.envVars[result.SessionID+":"+state.RuntimeDirEnv]; got != result.RuntimeDir {
		t.Fatalf("%s = %q, want %q", state.RuntimeDirEnv, got, result.RuntimeDir)
	}
	assertAbsent(t, filepath.Join("/tmp", result.SessionID))
}

// Deleting a new session removes its recorded directory.
func TestDeleteRemovesTheRecordedRuntimeDir(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = uniqueSessionClock()
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Shell: true})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if _, err := svc.Delete(t.Context(), result.SessionID); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	assertAbsent(t, result.RuntimeDir)
}

// A Pi session's messaging socket lives in its runtime directory, and a Unix
// socket path cannot exceed 103 bytes on macOS. A state root too long for it
// is refused at start with a clear error instead of a Pi that silently has no
// socket.
func TestStartRefusesAPiSessionWhoseSocketPathIsTooLong(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"pi": {CLI: "/bin/sh"}},
		Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "pi", Window: -1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	long, err := state.NewStore(filepath.Join(svc.Store.Root(), strings.Repeat("r", 80)))
	if err != nil {
		t.Fatal(err)
	}
	svc.Store = long
	svc.Registry = registry
	svc.Now = func() int64 { return 1700000102 }

	_, err = svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "Pi messaging socket") || !strings.Contains(err.Error(), state.StateRootEnv) {
		t.Fatalf("Start under a long root = %v, want the socket length error", err)
	}
	if runner.hasCall("new-session") {
		t.Fatal("Start created a tmux session for a Pi it cannot reach")
	}
	assertAbsent(t, filepath.Join(long.Root(), "runtime", state.NewSessionID(1700000102)))
}
