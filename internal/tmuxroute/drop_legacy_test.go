package tmuxroute

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"

	"github.com/alexivison/questmaster/internal/state"
)

func TestMissingServerFieldErrors(t *testing.T) {
	t.Parallel()
	r := testRouter(t, func(context.Context, ...string) (string, error) { return "", nil }, func(context.Context, ...string) (string, error) { return "", nil })
	for _, label := range []state.TmuxServer{"", "default"} {
		if _, err := r.Route(state.Manifest{SessionID: "qm-example", TmuxServer: label}); err == nil {
			t.Errorf("accepted ownership %q", label)
		}
	}
}

func TestAuditGateRejects(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, label, ids string
		unavailable      bool
	}{
		{name: "live default", label: "questmaster", ids: "qm-example"},
		{name: "orphan", ids: "qm-orphan"},
		{name: "unknown", label: ""},
		{name: "unavailable server", label: "questmaster", unavailable: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			r := New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{"default": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return tc.ids, nil })), "questmaster": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
				if tc.unavailable {
					return "", context.DeadlineExceeded
				}
				return "", nil
			}))}, func() string { return "questmaster" }, nil)
			if tc.name != "orphan" {
				if err := r.store.Create(state.Manifest{SessionID: "qm-example", TmuxServer: state.TmuxServer(tc.label)}); err != nil {
					t.Fatal(err)
				}
			}
			audit, err := r.Audit(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			switch tc.name {
			case "live default":
				if audit.Gate != "blocked" || len(audit.LiveLegacyManaged) != 1 || audit.LiveLegacyManaged[0] != "qm-example" {
					t.Fatalf("live default gate=%+v", audit)
				}
			case "unknown":
				if audit.Gate != "unknown" || len(audit.UnknownOwnership) != 1 || audit.UnknownOwnership[0] != "qm-example" {
					t.Fatalf("unknown gate=%+v", audit)
				}
			case "orphan":
				if audit.Gate != "blocked" || len(audit.Orphans) != 1 {
					t.Fatalf("orphan gate=%+v", audit)
				}
			case "unavailable server":
				if audit.Gate != "unknown" || audit.InventoryError == "" {
					t.Fatalf("unavailable gate=%+v", audit)
				}
			}

		})
	}
}

func TestDefaultProbeExcludedFromInventoryAndHandles(t *testing.T) {
	t.Parallel()
	calls := 0
	r := New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{
		"default":     tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { calls++; return "qm-sentinel", nil })),
		"questmaster": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil })),
	}, func() string { return "questmaster" }, nil)
	handles, err := r.KnownHandles()
	if err != nil {
		t.Fatal(err)
	}
	inv := r.Inventory(t.Context())
	if calls != 0 || len(handles) != 1 || handles[0].Label() != "questmaster" || len(inv.Servers) != 1 || inv.Servers[0].Label != "questmaster" {
		t.Fatalf("calls=%d handles=%v inventory=%+v", calls, handles, inv)
	}
}

func TestBackfillRechecksAfterLifecycleLock(t *testing.T) {
	for _, becomesLive := range []bool{false, true} {
		t.Run(fmt.Sprint(becomesLive), func(t *testing.T) {
			store := state.OpenStore(t.TempDir())
			if err := store.Create(state.Manifest{SessionID: "qm-locked"}); err != nil {
				t.Fatal(err)
			}
			var live atomic.Bool
			named := tmux.NewClient(runnerFunc(func(_ context.Context, args ...string) (string, error) {
				if args[0] == "list-sessions" {
					return "", nil
				}
				if args[0] == "has-session" {
					if live.Load() {
						return "", nil
					}
					return "", &tmux.ExitError{Code: 1}
				}
				t.Fatalf("unexpected command=%v", args)
				return "", nil
			}))
			r := New(store, map[string]*tmux.Client{"default": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil })), "questmaster": named}, func() string { return "questmaster" }, nil)
			held, release := make(chan struct{}), make(chan struct{})
			lockDone := make(chan error, 1)
			go func() {
				lockDone <- store.WithLifecycleLock("qm-locked", func() error { close(held); <-release; return nil })
			}()
			<-held
			defer func() {
				select {
				case <-release:
				default:
					close(release)
				}
				if err := <-lockDone; err != nil {
					t.Error(err)
				}
			}()
			type outcome struct {
				result BackfillResult
				err    error
			}
			done := make(chan outcome, 1)
			go func() { result, err := r.Backfill(t.Context()); done <- outcome{result, err} }()
			// Observe this Backfill inside the blocking lifecycle-lock acquisition,
			// rather than releasing it after an unrelated inventory call.
			deadline := time.NewTimer(3 * time.Second)
			defer deadline.Stop()
			ticker := time.NewTicker(time.Millisecond)
			defer ticker.Stop()
		waiting:
			for {
				select {
				case got := <-done:
					t.Fatalf("backfill completed while lifecycle lock held: %+v", got)
				case <-deadline.C:
					t.Fatal("backfill did not wait on lifecycle lock")
				case <-ticker.C:
					stack := make([]byte, 256*1024)
					n := runtime.Stack(stack, true)
					for _, goroutine := range strings.Split(string(stack[:n]), "\n\n") {
						if strings.Contains(goroutine, "tmuxroute.(*Router).Backfill") && strings.Contains(goroutine, "state.lockFile(") && strings.Contains(goroutine, "WithLifecycleLockContext(") {
							break waiting
						}
					}
				}
			}
			if becomesLive {
				live.Store(true)
			} else {
				if err := store.Update("qm-locked", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
					t.Fatal(err)
				}
			}
			close(release)
			got := <-done
			if got.err != nil {
				t.Fatal(got.err)
			}
			if got.result.Updated != 0 || got.result.Failed != 0 || (becomesLive && got.result.SkippedLive != 1) || (!becomesLive && got.result.SkippedAlreadySet != 1) {
				t.Fatalf("result=%+v", got.result)
			}
			m, err := store.Read("qm-locked")
			if err != nil {
				t.Fatal(err)
			}
			if becomesLive && m.TmuxServer != "" {
				t.Fatal("live session ownership rewritten")
			}
		})
	}
}

func TestIntegrationBackfillPreservesLiveDefaultSession(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", t.TempDir())
	first, second := tmuxtest.NewRunner(t), tmuxtest.NewRunner(t)
	if _, err := first.Run(t.Context(), "new-session", "-d", "-s", "qm-live", "sleep 60"); err != nil {
		t.Fatal(err)
	}
	store := state.OpenStore(t.TempDir())
	for _, id := range []string{"qm-live", "qm-stopped"} {
		if err := store.Create(state.Manifest{SessionID: id}); err != nil {
			t.Fatal(err)
		}
	}
	r := New(store, map[string]*tmux.Client{"default": tmux.NewClient(first), "questmaster": tmux.NewClient(second)}, func() string { return "questmaster" }, nil)
	result, err := r.Backfill(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 1 || result.SkippedLive != 1 || result.Failed != 0 {
		t.Fatalf("result=%+v", result)
	}
	m, _ := store.Read("qm-live")
	if m.TmuxServer != "" {
		t.Fatal("live session rewritten")
	}
	if live, err := tmux.NewClient(first).HasSession(t.Context(), "qm-live"); err != nil || !live {
		t.Fatalf("live=%v err=%v", live, err)
	}
	if _, err := os.Stat(second.Socket()); !os.IsNotExist(err) {
		t.Fatalf("backfill started dedicated server: %v", err)
	}
	audit, err := r.Audit(t.Context())
	if err != nil || audit.Gate == "ready" {
		t.Fatalf("audit=%+v err=%v", audit, err)
	}
}

func TestBackfillReportsCorruptManifest(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{SessionID: "qm-stopped"}); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store.Root(), "qm-corrupt.json"), []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	empty := tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))
	r := New(store, map[string]*tmux.Client{"default": empty, "questmaster": empty}, func() string { return "questmaster" }, nil)
	got, err := r.Backfill(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if got.Updated != 1 || got.Failed != 1 || len(got.Errors) != 1 {
		t.Fatalf("result=%+v", got)
	}
	audit, err := r.Audit(t.Context())
	if err != nil || audit.Gate != "unknown" {
		t.Fatalf("audit=%+v err=%v", audit, err)
	}
}

func TestBackfillSnapshotOnceAndAbortOnError(t *testing.T) {
	for _, failedServer := range []string{"none", "default", "questmaster"} {
		t.Run(failedServer, func(t *testing.T) {
			store := state.OpenStore(t.TempDir())
			for i := range 8 {
				if err := store.Create(state.Manifest{SessionID: fmt.Sprintf("qm-archive-%d", i)}); err != nil {
					t.Fatal(err)
				}
			}
			counts := map[string]int{}
			makeClient := func(label string) *tmux.Client {
				return tmux.NewClient(runnerFunc(func(_ context.Context, args ...string) (string, error) {
					if args[0] == "list-sessions" {
						counts[label]++
						if label == failedServer {
							return "", context.DeadlineExceeded
						}
						return "", nil
					}
					if args[0] == "has-session" {
						return "", &tmux.ExitError{Code: 1}
					}
					t.Fatalf("unexpected tmux command=%v", args)
					return "", nil
				}))
			}
			r := New(store, map[string]*tmux.Client{"default": makeClient("default"), "questmaster": makeClient("questmaster")}, func() string { return "questmaster" }, nil)
			got, err := r.Backfill(t.Context())
			if failedServer == "none" {
				if err != nil || got.Updated != 8 || got.Failed != 0 {
					t.Fatalf("result=%+v err=%v", got, err)
				}
			} else {
				if err == nil || got.Updated != 0 || got.Failed != 0 {
					t.Fatalf("snapshot should abort once: result=%+v err=%v", got, err)
				}
				for i := range 8 {
					m, err := store.Read(fmt.Sprintf("qm-archive-%d", i))
					if err != nil {
						t.Fatal(err)
					}
					if m.TmuxServer != "" {
						t.Fatal("snapshot error permitted a write")
					}
				}
			}
			wantDefault := 1
			if failedServer == "questmaster" {
				wantDefault = 0
			}
			if counts["questmaster"] != 1 || counts["default"] != wantDefault {
				t.Fatalf("snapshots=%v", counts)
			}
		})
	}
}
