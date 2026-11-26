package sessiontheme

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type themeRunner struct {
	live    []string
	accents map[string]string
	lists   int
	fail    bool
}

func (r *themeRunner) Run(_ context.Context, args ...string) (string, error) {
	if r.fail {
		return "", errors.New("transport unavailable")
	}
	if args[0] == "list-sessions" {
		r.lists++
		return strings.Join(r.live, "\n"), nil
	}
	if len(args) == 5 && args[0] == "set-option" && args[1] == "-t" && args[3] == AccentOption {
		r.accents[args[2]] = args[4]
		return "", nil
	}
	return "", fmt.Errorf("unexpected tmux call %q", args)
}

func TestSyncUsesTrackerColoursAndRecordedServers(t *testing.T) {
	t.Parallel()
	store := state.OpenStore(t.TempDir())
	folder := t.TempDir()
	projectID, projectPath, err := state.ProjectIDForFolder(folder)
	if err != nil {
		t.Fatal(err)
	}
	if err := state.NewProjectStore(store.Root()).Update(func(reg *state.ProjectRegistry) error {
		reg.SetPath(projectID, projectPath)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	create := func(id, server, parent, color string, shell bool) {
		t.Helper()
		m := state.Manifest{SessionID: id, Cwd: folder, TmuxServer: state.TmuxServer(server)}
		if !shell {
			m.Agents = []state.AgentManifest{{Name: "example-agent", Role: "agent"}}
		}
		if parent != "" {
			m.SetExtra("parent_session", parent)
			m.Cwd = filepath.Join(folder, "other-worktree")
		}
		if color != "" {
			m.Display = state.NewDisplayMetadata(color)
			m.Display.ColorChangedAt = "2025-01-01T00:00:00Z"
		}
		if err := store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	create("qm-master", "server_a", "", "blue", false)
	create("qm-worker", "server_b", "qm-master", "red", false)
	create("qm-shell", "server_a", "", "cyan", true)
	create("qm-stopped", "server_a", "", "red", false)
	create("qm-legacy", "default", "", "red", false)
	a := &themeRunner{live: []string{"qm-master", "qm-shell"}, accents: map[string]string{}}
	b := &themeRunner{live: []string{"qm-worker"}, accents: map[string]string{}}
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"server_a": tmux.NewClient(a), "server_b": tmux.NewClient(b),
	}, func() string { return "server_a" }, nil)
	assertColors := func(master, shell string) {
		t.Helper()
		if err := Sync(t.Context(), store, router, ""); err != nil {
			t.Fatal(err)
		}
		for _, want := range []struct {
			runner    *themeRunner
			id, color string
		}{
			{a, "qm-master", master}, {b, "qm-worker", master}, {a, "qm-shell", shell},
		} {
			if got := want.runner.accents[tmux.SessionTarget(want.id)]; got != palette.Display(want.color) {
				t.Errorf("%s accent = %q, want %q", want.id, got, palette.Display(want.color))
			}
		}
		if len(a.accents) != 2 || len(b.accents) != 1 {
			t.Fatalf("unexpected session targets: a=%v b=%v", a.accents, b.accents)
		}
	}
	assertColors("blue", "cyan")
	if a.lists != 1 || b.lists != 1 {
		t.Fatalf("inventory calls a=%d b=%d, want once per server", a.lists, b.lists)
	}
	if err := state.NewRepoColorStore(store.Root()).Set(projectID, "green"); err != nil {
		t.Fatal(err)
	}
	assertColors("green", "cyan")
	if err := store.SetDisplayColor("qm-master", "violet"); err != nil {
		t.Fatal(err)
	}
	assertColors("violet", "cyan")
	if err := store.SetDisplayColor("qm-master", "none"); err != nil {
		t.Fatal(err)
	}
	assertColors("none", "cyan")
	if err := store.SetDisplayColor("qm-master", ""); err != nil {
		t.Fatal(err)
	}
	assertColors("green", "cyan")
	// A transport failure must not route updates to another server.
	a.fail = true
	router.Invalidate()
	if err := Sync(t.Context(), store, router, ""); err == nil {
		t.Fatal("unavailable server was silently ignored")
	}
}

func TestSyncWorkerFollowsUncolouredMasterAndOrphanUsesOwnProject(t *testing.T) {
	t.Parallel()
	store := state.OpenStore(t.TempDir())
	projectID, projectPath, err := state.ProjectIDForFolder(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := state.NewProjectStore(store.Root()).Update(func(reg *state.ProjectRegistry) error {
		reg.SetPath(projectID, projectPath)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.NewRepoColorStore(store.Root()).Set(projectID, "pink"); err != nil {
		t.Fatal(err)
	}
	master := state.Manifest{SessionID: "qm-master", Cwd: t.TempDir(), TmuxServer: "example", Agents: []state.AgentManifest{{Name: "pi", Role: "agent"}}}
	worker := state.Manifest{SessionID: "qm-worker", Cwd: projectPath, TmuxServer: "example", Agents: master.Agents}
	worker.SetExtra("parent_session", master.SessionID)
	for _, m := range []*state.Manifest{&master, &worker} {
		m.RuntimeDir = state.NewRuntimeDir(store.Root(), m.SessionID)
		if err := state.EnsureRuntimeDir(m.RuntimeDir); err != nil {
			t.Fatal(err)
		}
		if err := store.Create(*m); err != nil {
			t.Fatal(err)
		}
	}
	runner := &themeRunner{live: []string{master.SessionID, worker.SessionID}, accents: map[string]string{}}
	router := tmuxroute.New(store, map[string]*tmux.Client{"example": tmux.NewClient(runner)}, func() string { return "example" }, nil)
	if err := Sync(t.Context(), store, router, master.SessionID); err != nil {
		t.Fatal(err)
	}
	if content, err := os.ReadFile(filepath.Join(master.RuntimeDir, piAccentFile)); err != nil || len(content) != 0 {
		t.Fatalf("uncoloured Pi launch wrote %q, %v; want an empty file", content, err)
	}
	if _, err := os.Stat(filepath.Join(worker.RuntimeDir, piAccentFile)); !os.IsNotExist(err) {
		t.Fatalf("targeted launch updated the worker: %v", err)
	}
	for _, step := range []struct{ name, parent, masterColor, workerColor string }{
		{"coloured master", master.SessionID, "blue", "blue"},
		{"uncoloured master", master.SessionID, "", ""},
		{"neutral master", master.SessionID, "none", "none"},
		{"orphan worker", "qm-missing", "", "pink"},
	} {
		t.Run(step.name, func(t *testing.T) {
			if err := store.SetDisplayColor(master.SessionID, step.masterColor); err != nil {
				t.Fatal(err)
			}
			if err := store.Update(worker.SessionID, func(m *state.Manifest) { m.SetExtra("parent_session", step.parent) }); err != nil {
				t.Fatal(err)
			}
			if err := Sync(t.Context(), store, router, ""); err != nil {
				t.Fatal(err)
			}
			if got := runner.accents[tmux.SessionTarget(worker.SessionID)]; got != palette.Display(step.workerColor) {
				t.Errorf("worker accent = %q, want %q", got, palette.Display(step.workerColor))
			}
			for _, target := range []struct {
				session state.Manifest
				color   string
			}{
				{master, step.masterColor}, {worker, step.workerColor},
			} {
				want := ""
				if target.color != "" && target.color != "none" {
					want = palette.Display(target.color)
				}
				got, err := os.ReadFile(filepath.Join(target.session.RuntimeDir, piAccentFile))
				if err != nil || string(got) != want {
					t.Errorf("%s live Pi colour = %q, %v; want %q", target.session.SessionID, got, err, want)
				}
			}
		})
	}
}
