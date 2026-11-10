package session

import (
	"context"
	"sync"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

// paneTitleWrites makes the mock runner record each managed pane-title write
// and run onFirstWrite before the first one lands.
type paneTitleWrites struct {
	mu           sync.Mutex
	titles       []string
	wrote        bool
	onFirstWrite func()
}

func (w *paneTitleWrites) install(runner *mockRunner) {
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "set-option" {
			if key, value := extractSetOption(args); key == "@questmaster_title" {
				w.mu.Lock()
				first := !w.wrote
				w.wrote = true
				w.mu.Unlock()
				if first && w.onFirstWrite != nil {
					w.onFirstWrite()
				}
				w.record(value)
				return "", nil
			}
		}
		return runner.defaultHandler(ctx, args...)
	}
}

func (w *paneTitleWrites) record(title string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.titles = append(w.titles, title)
}

func (w *paneTitleWrites) last() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.titles) == 0 {
		return ""
	}
	return w.titles[len(w.titles)-1]
}

// A rename that commits while the launched pane's title is being written,
// and whose own pane write lands first, still ends up on the pane.
func TestLaunchedPaneTitleLosesToRenameCommittedMeanwhile(t *testing.T) {
	svc, runner := setupService(t)
	const sessionID = "qm-launch-title-race"
	createTestManifest(t, svc.Store, sessionID, "Launch title", t.TempDir(), "")
	writes := &paneTitleWrites{}
	renamed := make(chan error, 1)
	writes.onFirstWrite = func() {
		go func() {
			err := svc.Store.Update(sessionID, func(m *state.Manifest) {
				m.Title = "Explicit title"
				m.SetExtra("title_locked", "1")
			})
			if err == nil {
				writes.record("Explicit title")
			}
			renamed <- err
		}()
		err := <-renamed
		renamed <- err
	}
	writes.install(runner)

	if err := svc.syncLaunchedPaneTitle(t.Context(), sessionID, "%1"); err != nil {
		t.Fatalf("sync launched pane title: %v", err)
	}
	if err := <-renamed; err != nil {
		t.Fatalf("rename: %v", err)
	}
	if got := writes.last(); got != "Explicit title" {
		t.Fatalf("final pane title = %q (writes %q), want the explicit title", got, writes.titles)
	}
}

// A pane-title write that hangs in tmux must not hold other manifest writers.
func TestLaunchedPaneTitleWriteDoesNotHoldTheManifestLock(t *testing.T) {
	svc, runner := setupService(t)
	const sessionID = "qm-launch-title-blocked"
	createTestManifest(t, svc.Store, sessionID, "Launch title", t.TempDir(), "")
	entered, release := make(chan struct{}), make(chan struct{})
	writes := &paneTitleWrites{onFirstWrite: func() {
		close(entered)
		<-release
	}}
	writes.install(runner)

	synced := make(chan error, 1)
	go func() { synced <- svc.syncLaunchedPaneTitle(t.Context(), sessionID, "%1") }()
	<-entered
	updated := make(chan error, 1)
	go func() { updated <- svc.Store.Update(sessionID, func(m *state.Manifest) { m.SetExtra("probe", "1") }) }()
	if err := <-updated; err != nil {
		t.Fatalf("manifest update: %v", err)
	}
	close(release)
	if err := <-synced; err != nil {
		t.Fatalf("sync launched pane title: %v", err)
	}
}
