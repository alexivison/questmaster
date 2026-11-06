package session

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestSecondMasterStartsWithoutExplicitClassOnNamedServer(t *testing.T) {
	svc, _, named := routedService(t)
	svc.Now = func() int64 { return 201 }
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if args[0] == "show-options" {
			return tmuxconfig.RootMarker(svc.Store.Root(), "test_named"), nil
		}
		return named.defaultHandler(ctx, args...)
	}
	first, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatal("first Start:", err)
	}
	t.Log("first Start created", first.SessionID)
	svc.Now = func() int64 { return 202 }
	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()}); err != nil {
		t.Fatal("second Start:", err)
	}
}

func TestMasterStartsWithLiveLegacyMasterAndNamedWorker(t *testing.T) {
	svc, legacy, named := routedService(t)
	createClassBackfillMaster(t, svc.Store, "qm-legacy-master", "wizard")
	legacy.sessions["qm-legacy-master"] = true
	if err := svc.Store.Create(state.Manifest{SessionID: "qm-named-worker", SessionType: "worker", TmuxServer: "test_named"}); err != nil {
		t.Fatal(err)
	}
	named.sessions["qm-named-worker"] = true
	svc.Now = func() int64 { return 203 }
	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()}); err != nil {
		t.Fatalf("Start with mixed live sessions: %v", err)
	}
}

func TestMasterStartsWhenClassHistoryHasUnroutableManifest(t *testing.T) {
	svc, _, _ := routedService(t)
	if err := svc.Store.Create(state.Manifest{SessionID: "qm-bad-route", TmuxServer: "bad label"}); err != nil {
		t.Fatal(err)
	}
	svc.Now = func() int64 { return 204 }
	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()}); err != nil {
		t.Fatalf("Start with unroutable history: %v", err)
	}
}

func TestMasterStartsWhenLegacyServerIsUnavailable(t *testing.T) {
	svc, legacy, _ := routedService(t)
	legacy.fn = func(ctx context.Context, args ...string) (string, error) {
		if args[0] == "list-sessions" || args[0] == "has-session" {
			return "", fmt.Errorf("legacy server unavailable")
		}
		return legacy.defaultHandler(ctx, args...)
	}
	svc.Now = func() int64 { return 205 }
	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()}); err != nil {
		t.Fatalf("Start with unavailable legacy server: %v", err)
	}
}

func TestFailedContinueRollbackKeepsLiveNamedRoute(t *testing.T) {
	svc, _, named := routedService(t)
	id := "qm-continue-kill-failed"
	stoppedLegacyWithResume(t, svc, id)
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if args[0] == "respawn-pane" {
			return "", fmt.Errorf("agent launch failed")
		}
		if args[0] == "kill-session" {
			return "", fmt.Errorf("temporary transport failure")
		}
		return named.defaultHandler(ctx, args...)
	}
	_, err := svc.Continue(t.Context(), id)
	if err == nil {
		t.Fatal("expected launch failure")
	}
	if !strings.Contains(err.Error(), "agent launch failed") || !strings.Contains(err.Error(), "temporary transport failure") {
		t.Fatalf("Continue error must include launch and rollback failures: %v", err)
	}
	m, readErr := svc.Store.Read(id)
	if readErr != nil {
		t.Fatal(readErr)
	}
	t.Logf("Continue error=%v; named server live=%v; recorded route=%q", err, named.sessions[id], m.TmuxServer)
	if named.sessions[id] && m.TmuxServer != state.TmuxServer("test_named") {
		t.Fatal("live named session lost its manifest route")
	}
}

func TestFailedStartRollbackKeepsLiveNamedManifest(t *testing.T) {
	svc, _, named := routedService(t)
	svc.Now = func() int64 { return 206 }
	named.fn = func(ctx context.Context, args ...string) (string, error) {
		if args[0] == "respawn-pane" {
			return "", fmt.Errorf("agent launch failed")
		}
		if args[0] == "kill-session" {
			return "", fmt.Errorf("temporary transport failure")
		}
		return named.defaultHandler(ctx, args...)
	}
	_, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err == nil || !strings.Contains(err.Error(), "rollback failed") {
		t.Fatalf("Start error = %v", err)
	}
	m, err := svc.Store.Read("qm-206")
	if err != nil || m.TmuxServer != "test_named" || !named.sessions["qm-206"] {
		t.Fatalf("live session lost its route: %+v, %v", m, err)
	}
}
