package tmuxroute

import (
	"context"
	"os"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
)

type runnerFunc func(context.Context, ...string) (string, error)

func (f runnerFunc) Run(ctx context.Context, args ...string) (string, error) { return f(ctx, args...) }

func testRouter(t *testing.T, defaultRun, namedRun runnerFunc) *Router {
	t.Helper()
	return New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{
		"default": tmux.NewClient(defaultRun), "questmaster": tmux.NewClient(namedRun),
	}, func() string { return "questmaster" }, nil)
}

func TestRouteAbsentIsLegacyEvenWhenCreationIsNamed(t *testing.T) {
	r := testRouter(t, func(context.Context, ...string) (string, error) { return "", nil }, func(context.Context, ...string) (string, error) { return "", nil })
	h, err := r.Route(state.Manifest{SessionID: "qm-old"})
	if err != nil {
		t.Fatal(err)
	}
	if h.Label() != "default" || h.SendLockNamespace() != "default" {
		t.Fatalf("route = %+v", h)
	}
	creation, err := r.Creation()
	if err != nil {
		t.Fatal(err)
	}
	if creation.Label() != "questmaster" {
		t.Fatalf("creation = %+v", creation)
	}
}

func TestRouteNamedConfigFilesAreCopied(t *testing.T) {
	r := New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{"default": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil })), "dev_recorded": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil }))}, func() string { return "default" }, []string{"/tmp/example/user.conf", "/tmp/example/enforced.conf"})
	h, err := r.Route(state.Manifest{TmuxServer: "dev_recorded"})
	if err != nil {
		t.Fatal(err)
	}
	files := h.ConfigFiles()
	files[0] = "changed"
	if h.Label() != "dev_recorded" || h.ConfigFiles()[0] != "/tmp/example/user.conf" {
		t.Fatalf("route = %+v, files = %v", h, h.ConfigFiles())
	}
}

func TestProductionRouteUsesRecordedLabel(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_current")
	defaultClient := tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil }))
	r, err := NewProduction(state.OpenStore(t.TempDir()), defaultClient)
	if err != nil {
		t.Fatal(err)
	}
	h, err := r.Route(state.Manifest{TmuxServer: "dev_recorded"})
	if err != nil {
		t.Fatal(err)
	}
	if h.Label() != "dev_recorded" || len(h.ConfigFiles()) != 2 {
		t.Fatalf("route = %+v", h)
	}
	creation, err := r.Creation()
	if err != nil {
		t.Fatal(err)
	}
	if creation.Label() != "dev_current" {
		t.Fatalf("creation label = %q", creation.Label())
	}
	legacy, err := r.Route(state.Manifest{})
	if err != nil || legacy.Label() != "default" {
		t.Fatalf("absent manifest route = %q, %v", legacy.Label(), err)
	}
}

func TestProductionRouterInventoriesPersistedLabels(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_current")
	root := t.TempDir()
	if err := state.RecordTmuxServerLabel(root, "dev_previous"); err != nil {
		t.Fatal(err)
	}
	r, err := NewProduction(state.OpenStore(root), tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return "", nil })))
	if err != nil {
		t.Fatal(err)
	}
	handles, err := r.KnownHandles()
	if err != nil {
		t.Fatal(err)
	}
	if len(handles) != 3 || handles[0].Label() != "default" || handles[1].Label() != "dev_current" || handles[2].Label() != "dev_previous" {
		t.Fatalf("known handles = %v", handles)
	}
}

func TestLiveIDsRejectsLabelRecordedAfterRouterCreation(t *testing.T) {
	root := t.TempDir()
	r := New(state.OpenStore(root), map[string]*tmux.Client{"default": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) {
		t.Fatal("inventory ran before checking the new label")
		return "", nil
	}))}, func() string { return "default" }, nil)
	if err := state.RecordTmuxServerLabel(root, "dev_previous"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.LiveIDs(t.Context()); err == nil {
		t.Fatal("destructive inventory treated an unrouteable recorded label as absent")
	}
}

func TestRouteUnknownLabelErrors(t *testing.T) {
	r := testRouter(t, func(context.Context, ...string) (string, error) { return "", nil }, func(context.Context, ...string) (string, error) { return "", nil })
	for _, label := range []string{"other", "bad label", "Default"} {
		if _, err := r.Route(state.Manifest{TmuxServer: state.TmuxServer(label)}); err == nil {
			t.Fatalf("accepted %q", label)
		}
	}
}

func TestInventoryOutcomes(t *testing.T) {
	for _, tc := range []struct {
		name   string
		output string
		err    error
		want   Outcome
	}{
		{"absent", "", &tmux.ExitError{Code: 1, Stderr: "no server running on /tmp/example"}, Absent},
		{"permission", "", &tmux.ExitError{Code: 1, Stderr: "error connecting to /tmp/example (Permission denied)"}, Unavailable},
		{"timeout", "", context.DeadlineExceeded, Unavailable},
		{"malformed", "qm-good\n\nqm-bad", nil, Unavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := testRouter(t, func(context.Context, ...string) (string, error) { return tc.output, tc.err }, func(context.Context, ...string) (string, error) {
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			})
			inv := r.Inventory(context.Background())
			if inv.Servers[0].Outcome != tc.want {
				t.Fatalf("outcome = %s, error = %s", inv.Servers[0].Outcome, inv.Servers[0].Error)
			}
		})
	}
}

func TestInventoryListsEachServerOnce(t *testing.T) {
	counts := map[string]int{}
	r := testRouter(t, func(context.Context, ...string) (string, error) { counts["default"]++; return "qm-a", nil }, func(context.Context, ...string) (string, error) { counts["questmaster"]++; return "qm-b", nil })
	r.Inventory(context.Background())
	r.Inventory(context.Background())
	if counts["default"] != 1 || counts["questmaster"] != 1 {
		t.Fatalf("counts = %v", counts)
	}
}

func TestInventoryDuplicateIDIsConflict(t *testing.T) {
	r := testRouter(t, func(context.Context, ...string) (string, error) { return "qm-same", nil }, func(context.Context, ...string) (string, error) { return "qm-same", nil })
	inv := r.Inventory(context.Background())
	if len(inv.Rows) != 2 || !inv.Rows[0].Conflict || !inv.Rows[1].Conflict {
		t.Fatalf("rows = %+v", inv.Rows)
	}
}

func TestAuditClassifiesOwnership(t *testing.T) {
	for _, tc := range []struct {
		name, defaultIDs, namedIDs, manifestServer, wantGate string
		corrupt                                              bool
		wantLegacy, wantOrphans, wantDuplicates, wantCorrupt int
	}{
		{"explicit default", "qm-example", "", "default", "blocked", false, 1, 0, 0, 0},
		{"manifestless", "qm-example", "", "", "blocked", false, 0, 1, 0, 0},
		{"duplicate", "qm-example", "qm-example", "default", "unknown", false, 1, 0, 1, 0},
		{"corrupt", "qm-example", "", "", "unknown", true, 0, 0, 0, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			store, err := state.NewStore(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if tc.manifestServer != "" {
				if err := store.Create(state.Manifest{SessionID: "qm-example", TmuxServer: state.TmuxServer(tc.manifestServer)}); err != nil {
					t.Fatal(err)
				}
			}
			if tc.corrupt {
				if err := os.WriteFile(store.Root()+"/qm-example.json", []byte("{"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			r := New(store, map[string]*tmux.Client{
				"default":     tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return tc.defaultIDs, nil })),
				"questmaster": tmux.NewClient(runnerFunc(func(context.Context, ...string) (string, error) { return tc.namedIDs, nil })),
			}, func() string { return "default" }, nil)
			a, err := r.Audit(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			if a.Gate != tc.wantGate || len(a.LiveLegacyManaged) != tc.wantLegacy || len(a.Orphans) != tc.wantOrphans || len(a.Duplicates) != tc.wantDuplicates || len(a.CorruptManifests) != tc.wantCorrupt {
				t.Fatalf("audit = %+v", a)
			}
		})
	}
}

func TestIntegrationInventoryTwoServers(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	first, second := tmuxtest.NewRunner(t), tmuxtest.NewRunner(t)
	if _, err := first.Run(t.Context(), "new-session", "-d", "-s", "qm-first"); err != nil {
		t.Fatal(err)
	}
	if _, err := second.Run(t.Context(), "new-session", "-d", "-s", "qm-second"); err != nil {
		t.Fatal(err)
	}
	r := New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{"default": tmux.NewClient(first), "questmaster": tmux.NewClient(second)}, func() string { return "default" }, nil)
	if inv := r.Inventory(t.Context()); len(inv.Rows) != 2 {
		t.Fatalf("rows = %+v", inv.Rows)
	}
	missing := tmuxtest.NewRunner(t)
	r = New(state.OpenStore(t.TempDir()), map[string]*tmux.Client{"default": tmux.NewClient(missing), "questmaster": tmux.NewClient(second)}, func() string { return "default" }, nil)
	if inv := r.Inventory(t.Context()); inv.Servers[0].Outcome != Absent {
		t.Fatalf("missing = %+v", inv.Servers[0])
	}
	if _, err := os.Stat(missing.Socket()); !os.IsNotExist(err) {
		t.Fatalf("listing created missing socket: %v", err)
	}
}
