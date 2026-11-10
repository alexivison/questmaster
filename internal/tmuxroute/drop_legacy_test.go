package tmuxroute

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

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
		{name: "live default", label: "default", ids: "qm-example"},
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
			if audit.Gate == "ready" {
				t.Fatalf("unsafe ready gate: %+v", audit)
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
	for _, live := range []bool{false, true} {
		t.Run(fmt.Sprint(live), func(t *testing.T) {
			r := testRouter(t, func(context.Context, ...string) (string, error) {
				if live {
					return "qm-locked", nil
				}
				return "", nil
			}, func(context.Context, ...string) (string, error) {
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			})
			// The default probe is separate; no second dedicated label is needed here.
			delete(r.clients, "dev_previous")
			if err := r.store.Create(state.Manifest{SessionID: "qm-locked"}); err != nil {
				t.Fatal(err)
			}
			held, release := make(chan struct{}), make(chan struct{})
			lockDone := make(chan error, 1)
			go func() {
				lockDone <- r.store.WithLifecycleLock("qm-locked", func() error {
					close(held)
					<-release
					if !live {
						return r.store.Update("qm-locked", func(m *state.Manifest) { m.TmuxServer = "questmaster" })
					}
					return nil
				})
			}()
			<-held
			listed := make(chan struct{}, 1)
			r.clients["questmaster"] = tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
				select {
				case listed <- struct{}{}:
				default:
				}
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			}))
			type outcome struct {
				result BackfillResult
				err    error
			}
			done := make(chan outcome, 1)
			go func() { result, err := r.Backfill(t.Context()); done <- outcome{result, err} }()
			<-listed
			close(release)
			if err := <-lockDone; err != nil {
				t.Fatal(err)
			}
			got := <-done
			if got.err != nil {
				t.Fatal(got.err)
			}
			if got.result.Updated != 0 || got.result.Failed != 0 || (live && got.result.SkippedLive != 1) || (!live && got.result.SkippedAlreadySet != 1) {
				t.Fatalf("result=%+v", got.result)
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

func TestBackfillReportsCorruptAndUnavailableCandidates(t *testing.T) {
	for _, unavailable := range []string{"none", "default", "questmaster"} {
		t.Run(unavailable, func(t *testing.T) {
			store := state.OpenStore(t.TempDir())
			if err := store.Create(state.Manifest{SessionID: "qm-stopped"}); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(store.Root(), "qm-corrupt.json"), []byte("{"), 0600); err != nil {
				t.Fatal(err)
			}
			r := New(store, map[string]*tmux.Client{
				"default": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
					if unavailable == "default" {
						return "", context.DeadlineExceeded
					}
					return "", nil
				})),
				"questmaster": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
					if unavailable == "questmaster" {
						return "", context.DeadlineExceeded
					}
					return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
				})),
			}, func() string { return "questmaster" }, nil)
			got, err := r.Backfill(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			wantUpdated, wantFailed := 1, 1
			if unavailable != "none" {
				wantUpdated, wantFailed = 0, 2
			}
			if got.Updated != wantUpdated || got.Failed != wantFailed || len(got.Errors) != wantFailed {
				t.Fatalf("result=%+v", got)
			}
			audit, err := r.Audit(t.Context())
			if err != nil || audit.Gate != "unknown" {
				t.Fatalf("audit=%+v err=%v", audit, err)
			}
		})
	}
}
