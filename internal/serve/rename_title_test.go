package serve

import (
	"context"
	"sync"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

// paneTitleRunner answers the tmux calls a rename makes, records each managed
// pane-title write, and runs onFirstWrite before the first one lands.
type paneTitleRunner struct {
	mu           sync.Mutex
	titles       []string
	wrote        bool
	onFirstWrite func()
}

func (r *paneTitleRunner) Run(_ context.Context, args ...string) (string, error) {
	switch {
	case len(args) == 0:
		return "", nil
	case args[0] == "list-panes":
		return "0 0 agent", nil
	case args[0] == "display-message":
		return "#{pane_title}", nil
	case args[0] == "set-option" && len(args) == 6 && args[4] == "@questmaster_title":
		r.mu.Lock()
		first := !r.wrote
		r.wrote = true
		r.mu.Unlock()
		if first && r.onFirstWrite != nil {
			r.onFirstWrite()
		}
		r.record(args[5])
	}
	return "", nil
}

func (r *paneTitleRunner) record(title string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.titles = append(r.titles, title)
}

func (r *paneTitleRunner) last() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.titles) == 0 {
		return ""
	}
	return r.titles[len(r.titles)-1]
}

func TestRenameRoutesToRecordedServer(t *testing.T) {
	env := seedServeFixture(t)
	if err := env.store.Update("qm-demo", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
		t.Fatal(err)
	}
	legacy, named := &paneTitleRunner{}, &paneTitleRunner{}
	router := tmuxroute.New(env.store, map[string]*tmux.Client{"dev_previous": tmux.NewClient(legacy), "questmaster": tmux.NewClient(named)}, func() string { return "dev_previous" }, nil)
	srv := &Server{Snapshotter: testSnapshotter(env.store, tmux.NewClient(legacy), nil), TmuxRouter: router}
	if _, err := srv.mutateRename(t.Context(), mutationPayload{SessionID: "qm-demo", Title: "Routed title"}); err != nil {
		t.Fatal(err)
	}
	if legacy.last() != "" || named.last() != "Routed title" {
		t.Fatalf("titles: legacy=%q named=%q", legacy.last(), named.last())
	}
}

// Two renames: the second commits while the first one's pane write is in
// flight and its own write lands first. The pane ends with the second title.
func TestRenamePaneWriteLosesToRenameCommittedMeanwhile(t *testing.T) {
	env := seedServeFixture(t)
	runner := &paneTitleRunner{}
	srv := &Server{Snapshotter: testSnapshotter(env.store, tmux.NewClient(runner), nil)}
	srv.TmuxRouter = srv.Snapshotter.router
	renamed := make(chan error, 1)
	runner.onFirstWrite = func() {
		go func() {
			err := env.store.Update("qm-demo", func(m *state.Manifest) {
				m.Title = "Second title"
				m.SetExtra("title_locked", "1")
			})
			if err == nil {
				runner.record("Second title")
			}
			renamed <- err
		}()
		err := <-renamed
		renamed <- err
	}

	if _, err := srv.mutateRename(t.Context(), mutationPayload{SessionID: "qm-demo", Title: "First title"}); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if err := <-renamed; err != nil {
		t.Fatalf("second rename: %v", err)
	}
	if got := runner.last(); got != "Second title" {
		t.Fatalf("final pane title = %q (writes %q), want the second title", got, runner.titles)
	}
}

// A pane-title write that hangs in tmux must not hold other manifest writers.
func TestRenamePaneWriteDoesNotHoldTheManifestLock(t *testing.T) {
	env := seedServeFixture(t)
	entered, release := make(chan struct{}), make(chan struct{})
	runner := &paneTitleRunner{onFirstWrite: func() {
		close(entered)
		<-release
	}}
	srv := &Server{Snapshotter: testSnapshotter(env.store, tmux.NewClient(runner), nil)}
	srv.TmuxRouter = srv.Snapshotter.router

	renamed := make(chan error, 1)
	go func() {
		_, err := srv.mutateRename(t.Context(), mutationPayload{SessionID: "qm-demo", Title: "New title"})
		renamed <- err
	}()
	<-entered
	updated := make(chan error, 1)
	go func() { updated <- env.store.Update("qm-demo", func(m *state.Manifest) { m.SetExtra("probe", "1") }) }()
	if err := <-updated; err != nil {
		t.Fatalf("manifest update: %v", err)
	}
	close(release)
	if err := <-renamed; err != nil {
		t.Fatalf("rename: %v", err)
	}
}
