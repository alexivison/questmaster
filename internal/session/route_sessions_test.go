package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestStartRecordsServerBeforeLaunch(t *testing.T) {
	svc, legacy, named := routedService(t)
	svc.Now = func() int64 { return 101 }
	seenLaunch := false
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "respawn-pane" {
			id := "qm-101"
			m, err := svc.Store.Read(id)
			if err != nil || m.TmuxServer != "test_named" {
				return "", fmt.Errorf("route at agent launch = %q, %v", m.TmuxServer, err)
			}
			seenLaunch = true
		}
		return named.defaultHandler(ctx, args...)
	}
	result, err := svc.Start(context.Background(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if m.TmuxServer != "test_named" {
		t.Fatalf("tmux_server = %q", m.TmuxServer)
	}
	if !named.sessions[result.SessionID] || legacy.sessions[result.SessionID] {
		t.Fatal("session started on wrong server")
	}
	if !seenLaunch {
		t.Fatal("agent launch not observed")
	}
}

func routedService(t *testing.T) (*Service, *mockRunner, *mockRunner) {
	t.Helper()
	t.Setenv("QUESTMASTER_TMUX_LABEL", "test_named")
	tmuxtest.StubQuestmaster(t)
	svc, legacy := setupService(t)
	named := newMockRunner()
	named.ownerMarker = tmuxconfig.RootMarker(svc.Store.Root(), "test_named")
	svc.Router = tmuxroute.New(svc.Store, map[string]*tmux.Client{
		"default": svc.Client, "test_named": tmux.NewClient(named),
	}, func() string { return "test_named" }, nil)
	return svc, legacy, named
}

func TestStartRefusesForeignNamedServer(t *testing.T) {
	svc, legacy, named := routedService(t)
	named.sessions["qm-sentinel"] = true
	foreign := tmuxconfig.RootMarker(t.TempDir(), "test_named")
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "show-options" {
			return foreign, nil
		}
		return named.defaultHandler(ctx, args...)
	}
	_, err := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "unmarked or belongs to another state root") {
		t.Fatalf("Start error = %v", err)
	}
	if len(callsAfter(named, 0, "new-session")) != 0 || len(callsAfter(named, 0, "kill-session")) != 0 {
		t.Fatal("foreign named server was mutated")
	}
	if len(callsAfter(legacy, 0, "kill-session")) != 0 {
		t.Fatal("legacy server was killed")
	}
}

func TestStartAcceptsOwnedNamedServer(t *testing.T) {
	svc, _, named := routedService(t)
	named.sessions["qm-sentinel"] = true
	marker := tmuxconfig.RootMarker(svc.Store.Root(), "test_named")
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "show-options" {
			return marker, nil
		}
		return named.defaultHandler(ctx, args...)
	}
	result, err := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if !named.sessions[result.SessionID] || !named.sessions["qm-sentinel"] {
		t.Fatal("owned server session missing")
	}
}

func TestStartIDCollisionChecksBothServers(t *testing.T) {
	svc, legacy, named := routedService(t)
	svc.Now = func() int64 { return 101 }
	svc.RandSuffix = func() int64 { return 7 }
	legacy.sessions["qm-101"] = true
	result, err := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if result.SessionID != "qm-101-7" || !legacy.sessions["qm-101"] || !named.sessions[result.SessionID] {
		t.Fatalf("collision result = %s", result.SessionID)
	}
	if len(callsAfter(legacy, 0, "kill-session")) != 0 {
		t.Fatal("collision check killed legacy occupant")
	}
}

func stoppedLegacyWithResume(t *testing.T, svc *Service, id string) {
	t.Helper()
	createTestManifest(t, svc.Store, id, "work", t.TempDir(), "")
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.Agents[0].ResumeID = "resume-1" }); err != nil {
		t.Fatal(err)
	}
}

func TestStartRollbackRestoresOnlyRouting(t *testing.T) {
	svc, _, named := routedService(t)
	id := "qm-rollback-routing"
	stoppedLegacyWithResume(t, svc, id)
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.SetExtra("keep", "value") }); err != nil {
		t.Fatal(err)
	}
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "set-environment" {
			return "", errors.New("setup failed")
		}
		return named.defaultHandler(ctx, args...)
	}
	if _, err := svc.Continue(t.Context(), id); err == nil {
		t.Fatal("Continue succeeded")
	}
	m, err := svc.Store.Read(id)
	if err != nil {
		t.Fatal(err)
	}
	if m.TmuxServer != "" || m.ExtraString("keep") != "value" || m.Agents[0].ResumeID != "resume-1" {
		t.Fatalf("rollback changed manifest: %+v", m)
	}
	if !named.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("new session survived rollback")
	}
}

func TestContinueStoppedLegacyRecreatesOnCreationServer(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-stopped-legacy-route"
	stoppedLegacyWithResume(t, svc, id)
	if _, err := svc.Continue(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	if !named.sessions[id] || legacy.sessions[id] {
		t.Fatal("session reconstructed on wrong server")
	}
	m, err := svc.Store.Read(id)
	if err != nil || m.TmuxServer != "test_named" {
		t.Fatalf("route = %+v, %v", m.TmuxServer, err)
	}
	if command := findLaunchArgContaining(named, "--resume 'resume-1'"); command == "" {
		t.Fatal("resume command missing")
	}
}

func TestContinueMissingResumeIDErrors(t *testing.T) {
	svc, _, named := routedService(t)
	id := "qm-missing-resume-route"
	createTestManifest(t, svc.Store, id, "work", t.TempDir(), "")
	_, err := svc.Continue(t.Context(), id)
	if err == nil || !strings.Contains(err.Error(), "no saved agent resume ID") {
		t.Fatalf("Continue error = %v", err)
	}
	if len(callsAfter(named, 0, "new-session")) != 0 {
		t.Fatal("started a new conversation")
	}
}

func TestDeleteKillsOnOwnServerOnly(t *testing.T) {
	svc, legacy, named := routedService(t)
	master, worker := "qm-route-master", "qm-route-worker"
	createTestManifest(t, svc.Store, master, "master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, worker, "worker", t.TempDir(), "")
	if err := svc.Store.Update(worker, func(m *state.Manifest) { m.TmuxServer = "test_named"; m.SetExtra("parent_session", master) }); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.AddWorker(master, worker); err != nil {
		t.Fatal(err)
	}
	legacy.sessions[master], named.sessions[worker] = true, true
	if _, err := svc.Delete(t.Context(), master); err != nil {
		t.Fatal(err)
	}
	if !legacy.hasCall("kill-session", "-t", tmux.SessionTarget(master)) || !named.hasCall("kill-session", "-t", tmux.SessionTarget(worker)) {
		t.Fatal("recorded kills missing")
	}
	if legacy.hasCall("kill-session", "-t", tmux.SessionTarget(worker)) || named.hasCall("kill-session", "-t", tmux.SessionTarget(master)) {
		t.Fatal("cross-server kill")
	}
}

func TestDeleteOrphanMasterOnDefault(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-orphan-default"
	legacy.sessions[id] = true
	if _, err := svc.Delete(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	if legacy.sessions[id] || !legacy.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("default orphan survived")
	}
	if named.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("named server was killed")
	}
}

func TestDeleteOrphanMasterOnNamed(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-orphan-named"
	named.sessions[id] = true
	if _, err := svc.Delete(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	if named.sessions[id] || !named.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("named orphan survived")
	}
	if legacy.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("default server was killed")
	}
}

func TestDeleteManifestlessWorkerInCascade(t *testing.T) {
	svc, legacy, named := routedService(t)
	master, worker := "qm-master-with-orphan", "qm-worker-without-manifest"
	createTestManifest(t, svc.Store, master, "master", t.TempDir(), "master")
	if err := svc.Store.AddWorker(master, worker); err != nil {
		t.Fatal(err)
	}
	legacy.sessions[master], named.sessions[worker] = true, true
	if _, err := svc.Delete(t.Context(), master); err != nil {
		t.Fatal(err)
	}
	if named.sessions[worker] || !named.hasCall("kill-session", "-t", tmux.SessionTarget(worker)) {
		t.Fatal("manifest-less worker survived cascade")
	}
	if legacy.hasCall("kill-session", "-t", tmux.SessionTarget(worker)) {
		t.Fatal("worker killed on wrong server")
	}
}

func TestDeleteOrphanChecksEveryServerBeforeKilling(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-orphan-unavailable"
	legacy.sessions[id] = true
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "list-sessions" {
			return "", &tmux.ExitError{Code: 1, Stderr: "permission denied"}
		}
		return named.defaultHandler(ctx, args...)
	}
	if _, err := svc.Delete(t.Context(), id); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("Delete error = %v", err)
	}
	if !legacy.sessions[id] || legacy.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("deleted orphan with an unavailable server")
	}
}

func TestDeleteDuplicateOrphanOnBothServers(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-orphan-duplicate"
	legacy.sessions[id], named.sessions[id] = true, true
	if _, err := svc.Delete(t.Context(), id); err != nil {
		t.Fatal(err)
	}
	if legacy.sessions[id] || named.sessions[id] {
		t.Fatal("duplicate orphan survived")
	}
	if !legacy.hasCall("kill-session", "-t", tmux.SessionTarget(id)) || !named.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("duplicate orphan kill missing")
	}
}

func TestSpawnWorkerUsesCreationServerUnderLegacyMaster(t *testing.T) {
	svc, legacy, named := routedService(t)
	master := "qm-spawn-legacy-master"
	createTestManifest(t, svc.Store, master, "master", t.TempDir(), "master")
	legacy.sessions[master] = true
	result, err := svc.Spawn(t.Context(), master, SpawnOpts{Title: "worker", Cwd: t.TempDir(), Registry: svc.Registry})
	if err != nil {
		t.Fatal(err)
	}
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if m.TmuxServer != "test_named" || !named.sessions[result.SessionID] || legacy.sessions[result.SessionID] {
		t.Fatalf("worker route = %q", m.TmuxServer)
	}
}

func TestContinueDeadNamedPaneRespawnsInPlace(t *testing.T) {
	svc, legacy, named := routedService(t)
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "resume-1"}})
	if err != nil {
		t.Fatal(err)
	}
	pane := named.sessionPane(result.SessionID)
	named.deadPanes[pane] = "17"
	before := len(named.calls)
	continued, err := svc.Continue(t.Context(), result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if !continued.Respawned || !continued.Reattach {
		t.Fatalf("Continue = %+v", continued)
	}
	if len(callsAfter(named, before, "new-session")) != 0 || len(callsAfter(legacy, 0, "new-session")) != 0 {
		t.Fatal("dead named pane moved servers")
	}
	respawns := callsAfter(named, before, "respawn-pane")
	if len(respawns) != 1 || flagVal(respawns[0], "-t") != pane {
		t.Fatalf("respawn calls = %v", respawns)
	}
}

func legacyDeadAgent(t *testing.T, svc *Service, legacy *mockRunner, id string) string {
	t.Helper()
	stoppedLegacyWithResume(t, svc, id)
	pane := legacy.addSession(id)
	legacy.paneRoles[legacy.paneIDs[pane]] = tmux.RoleAgent
	legacy.deadPanes[pane] = "17"
	dir := state.NewRuntimeDir(svc.Store.Root(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cleanup.sh"), []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.RuntimeDir = dir }); err != nil {
		t.Fatal(err)
	}
	return pane
}

func TestContinueDeadLegacyContainerRetires(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-dead-legacy-container"
	legacyDeadAgent(t, svc, legacy, id)
	result, err := svc.Continue(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	if result.Reattach || !named.sessions[id] || legacy.sessions[id] {
		t.Fatalf("Continue = %+v", result)
	}
	if !legacy.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatal("dead legacy container not retired")
	}
	if _, err := os.Stat(filepath.Join(state.NewRuntimeDir(svc.Store.Root(), id), "cleanup.sh.retired")); err != nil {
		t.Fatal("legacy cleanup not fenced", err)
	}
}

func TestContinueDeadLegacyMissingResumeIDExplainsRecovery(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-dead-no-resume"
	legacyDeadAgent(t, svc, legacy, id)
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.Agents[0].ResumeID = "" }); err != nil {
		t.Fatal(err)
	}
	_, err := svc.Continue(t.Context(), id)
	if err == nil || !strings.Contains(err.Error(), "qm delete "+id) || !strings.Contains(err.Error(), "start a new session") {
		t.Fatalf("Continue error = %v", err)
	}
	if !legacy.sessions[id] || len(callsAfter(named, 0, "new-session")) != 0 {
		t.Fatal("dead container changed without a resume ID")
	}
}

func TestContinueLegacyWithLiveEditorRespawnsInPlace(t *testing.T) {
	svc, legacy, named := routedService(t)
	id := "qm-legacy-live-editor"
	agentPane := legacyDeadAgent(t, svc, legacy, id)
	editorPane := legacy.addSession("qm-unused-editor")
	legacy.paneIDs[editorPane] = id + ":2.1"
	delete(legacy.sessions, "qm-unused-editor")
	result, err := svc.Continue(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	if !result.Reattach || !result.Respawned || !legacy.sessions[id] {
		t.Fatalf("Continue = %+v", result)
	}
	if len(callsAfter(legacy, 0, "kill-session")) != 0 || len(callsAfter(named, 0, "new-session")) != 0 {
		t.Fatal("live editor container retired")
	}
	respawns := callsAfter(legacy, 0, "respawn-pane")
	if len(respawns) != 1 || flagVal(respawns[0], "-t") != agentPane {
		t.Fatalf("agent not respawned in place: %v", respawns)
	}
}

func TestCascadeResolvesEachWorker(t *testing.T) {
	svc, legacy, named := routedService(t)
	master, worker := "qm-cascade-master", "qm-cascade-worker"
	createTestManifest(t, svc.Store, master, "master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, worker, "worker", t.TempDir(), "")
	if err := svc.Store.Update(worker, func(m *state.Manifest) { m.TmuxServer = "test_named"; m.SetExtra("parent_session", master) }); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.AddWorker(master, worker); err != nil {
		t.Fatal(err)
	}
	legacy.sessions[master], named.sessions[worker] = true, true
	result, err := svc.Continue(t.Context(), master)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.RevivedWorkers) != 0 || len(result.FailedWorkers) != 0 {
		t.Fatalf("cascade = %+v", result)
	}
	if len(callsAfter(named, 0, "new-session")) != 0 {
		t.Fatal("live worker recreated")
	}
}

func TestSessionClosedSkipsLiveIncarnation(t *testing.T) {
	svc, _, named := routedService(t)
	id := "qm-live-incarnation"
	createTestManifest(t, svc.Store, id, "work", t.TempDir(), "")
	dir := state.NewRuntimeDir(svc.Store.Root(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.TmuxServer = "test_named"; m.RuntimeDir = dir }); err != nil {
		t.Fatal(err)
	}
	named.sessions[id] = true
	if err := svc.SessionClosed(t.Context(), "test_named", id); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("live runtime dir removed", err)
	}
}

func TestSessionClosedSkipsMovedServer(t *testing.T) {
	svc, _, _ := routedService(t)
	id := "qm-moved-incarnation"
	createTestManifest(t, svc.Store, id, "work", t.TempDir(), "")
	dir := state.NewRuntimeDir(svc.Store.Root(), id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.Update(id, func(m *state.Manifest) { m.TmuxServer = "default"; m.RuntimeDir = dir }); err != nil {
		t.Fatal(err)
	}
	if err := svc.SessionClosed(t.Context(), "test_named", id); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatal("moved runtime dir removed", err)
	}
}

func TestSessionClosedDeregistersAndRemoves(t *testing.T) {
	svc, _, _ := routedService(t)
	master, worker := "qm-clean-master", "qm-clean-worker"
	createTestManifest(t, svc.Store, master, "master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, worker, "worker", t.TempDir(), "")
	dir := state.NewRuntimeDir(svc.Store.Root(), worker)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.Update(worker, func(m *state.Manifest) {
		m.TmuxServer = "test_named"
		m.RuntimeDir = dir
		m.SetExtra("parent_session", master)
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.Store.AddWorker(master, worker); err != nil {
		t.Fatal(err)
	}
	if err := svc.SessionClosed(t.Context(), "test_named", worker); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("runtime dir remains: %v", err)
	}
	m, err := svc.Store.Read(master)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Workers) != 0 {
		t.Fatalf("workers = %v", m.Workers)
	}
	if _, err := svc.Store.Read(worker); err != nil {
		t.Fatal("stopped manifest removed", err)
	}
}

func TestSessionClosedLockTimeoutExitsZero(t *testing.T) {
	svc, _, _ := routedService(t)
	id := "qm-closed-lock"
	entered := make(chan struct{})
	release := make(chan struct{})
	go func() { _ = svc.Store.WithLifecycleLock(id, func() error { close(entered); <-release; return nil }) }()
	<-entered
	defer close(release)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
	defer cancel()
	if err := svc.SessionClosed(ctx, "test_named", id); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lock error = %v", err)
	}
}
