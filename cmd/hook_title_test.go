package cmd

import (
	"bytes"
	"context"
	"io"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestFirstPromptTitleDoesNotOverrideConcurrentExplicitRename(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "agent"}}
	tmuxStub := &tmuxEnvStub{}
	store.afterUpdate = func(m *state.Manifest) {
		m.Title = "Explicit title"
		m.SetExtra("title_locked", "1")
		_ = tmuxStub.SelectPaneTitle(t.Context(), "qm-t:0.0", "Explicit title")
	}
	r.Store = store
	r.TmuxClient = tmuxStub

	var stderr bytes.Buffer
	maybeDeriveTitle(t.Context(), r, "qm-t", "Derived title", &stderr)
	if stderr.Len() != 0 {
		t.Fatalf("hook stderr = %q", stderr.String())
	}
	if store.manifest.Title != "Explicit title" {
		t.Fatalf("manifest title = %q", store.manifest.Title)
	}
	if got := tmuxStub.paneTitleCalls[len(tmuxStub.paneTitleCalls)-1].name; got != "Explicit title" {
		t.Fatalf("last pane title = %q, want explicit title", got)
	}
}

func TestFirstPromptTitleTargetsAdoptedAgentPane(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{"adopted_pane": "%7"})
	store.manifest.Agents = []state.AgentManifest{{Name: "claude", Role: "agent"}}
	tmuxStub := &tmuxEnvStub{resolvedPane: "qm-t:0.1"}
	r.Store = store
	r.TmuxClient = tmuxStub

	var stderr bytes.Buffer
	maybeDeriveTitle(t.Context(), r, "qm-t", "Adopted title", &stderr)
	if stderr.Len() != 0 {
		t.Fatalf("hook stderr = %q", stderr.String())
	}
	if len(tmuxStub.paneTitleCalls) != 1 || tmuxStub.paneTitleCalls[0] != (tmuxRenameCall{target: "qm-t:0.1", name: "Adopted title"}) {
		t.Fatalf("agent pane title calls = %+v", tmuxStub.paneTitleCalls)
	}
}

// startThenPrompt drives the SessionStart → first-prompt sequence that the
// title heuristic keys off of. rec.lastState persists between the two calls,
// so the second call sees the pane still in its "starting" state.
func TestHookClaudeDerivesTitleOnFirstPrompt(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "claude", Role: "agent"}}
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "investigate the flaky test" {
		t.Fatalf("title = %q, want %q", store.manifest.Title, "investigate the flaky test")
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0", len(tmuxStub.renameCalls))
	}
	if len(tmuxStub.paneTitleCalls) != 1 || tmuxStub.paneTitleCalls[0].target != "=qm-t:0.0" || tmuxStub.paneTitleCalls[0].name != "investigate the flaky test" {
		t.Fatalf("pane title calls = %+v", tmuxStub.paneTitleCalls)
	}
}

func TestHookClaudeDoesNotDeriveTitleMidConversation(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	// A "working" action without a preceding "starting" is not a first turn;
	// the title must stay blank and the window must not be renamed.
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "some later message"})

	if store.manifest.Title != "" {
		t.Fatalf("title = %q, want blank (mid-conversation turn)", store.manifest.Title)
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0", len(tmuxStub.renameCalls))
	}
}

func TestHookDerivesTitleOverProvisionalTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{"title_provisional": "1"})
	store.manifest.Title = "repo"
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "investigate the flaky test" {
		t.Fatalf("title = %q, want derived prompt title", store.manifest.Title)
	}
	if store.manifest.ExtraString("title_provisional") != "" {
		t.Fatalf("title_provisional = %q, want cleared", store.manifest.ExtraString("title_provisional"))
	}
	if store.manifest.WindowName != "" {
		t.Fatalf("window_name = %q, want blank", store.manifest.WindowName)
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0", len(tmuxStub.renameCalls))
	}
}

func TestHookDoesNotOverwriteExistingTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{"title_locked": "1"})
	store.manifest.Title = "deliberate name"
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "deliberate name" {
		t.Fatalf("title = %q, want unchanged %q", store.manifest.Title, "deliberate name")
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0 (existing title)", len(tmuxStub.renameCalls))
	}
}

func TestHookRespectsLockedTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{"title_locked": "1"})
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "" {
		t.Fatalf("title = %q, want blank (locked)", store.manifest.Title)
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0 (locked title)", len(tmuxStub.renameCalls))
	}
}

func TestHookCodexDerivesTitleOnFirstPrompt(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "agent"}}
	r.Store = store
	tmuxStub := &tmuxEnvStub{}
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "codex", "starting", "qm-t", nil)
	runHookWithStdin(r, "codex", "working", "qm-t", map[string]interface{}{"prompt": "add a retry to the uploader"})

	if store.manifest.Title != "add a retry to the uploader" {
		t.Fatalf("title = %q, want %q", store.manifest.Title, "add a retry to the uploader")
	}
	if len(tmuxStub.paneTitleCalls) != 1 || tmuxStub.paneTitleCalls[0].target != "=qm-t:0.0" || tmuxStub.paneTitleCalls[0].name != "add a retry to the uploader" {
		t.Fatalf("pane title calls = %+v", tmuxStub.paneTitleCalls)
	}
}

func TestHookPiDerivesTitleOnSessionStart(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	// Pi delivers the first user message on session_start itself.
	runHookWithStdin(r, "pi", "session_start", "qm-t", map[string]interface{}{"prompt": "document the picker flow"})

	if store.manifest.Title != "document the picker flow" {
		t.Fatalf("title = %q, want %q", store.manifest.Title, "document the picker flow")
	}
}

func TestHookDerivesTitleForMasterWithoutRenamingWindow(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{})
	store.manifest.SessionType = "master"
	tmuxStub := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxStub

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "triage the release"})

	if store.manifest.Title != "triage the release" {
		t.Fatalf("title = %q, want derived title", store.manifest.Title)
	}
	if len(tmuxStub.renameCalls) != 0 {
		t.Fatalf("rename calls = %d, want 0", len(tmuxStub.renameCalls))
	}
}

// titleRaceTmux stands in for tmux while a derived title is written to the
// pane. Its first pane-title write runs onFirstWrite before the write lands,
// so a test can commit an explicit rename at the worst moment: after the
// derived title committed, before its pane write landed.
type titleRaceTmux struct {
	*tmuxEnvStub
	mu           sync.Mutex
	titles       []string
	wrote        bool
	onFirstWrite func()
}

func (c *titleRaceTmux) SetManagedPaneTitle(_ context.Context, _ string, title string) error {
	c.mu.Lock()
	first := !c.wrote
	c.wrote = true
	c.mu.Unlock()
	if first && c.onFirstWrite != nil {
		c.onFirstWrite()
	}
	c.recordTitle(title)
	return nil
}

func (c *titleRaceTmux) recordTitle(title string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.titles = append(c.titles, title)
}

func (c *titleRaceTmux) lastTitle() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.titles) == 0 {
		return ""
	}
	return c.titles[len(c.titles)-1]
}

func newTitledAgentSession(t *testing.T, sessionID string) *state.Store {
	t.Helper()
	store, err := state.NewStore(setTestStateRoot(t))
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{TmuxServer: "dev_previous", SessionID: sessionID, Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	return store
}

// An explicit rename that commits after the derived title committed, and
// whose own pane write lands before the derived one, still ends up on the
// pane. The derived title's pane write runs outside the manifest lock, so the
// rename can commit at that moment.
func TestDerivedTitlePaneWriteLosesToRenameCommittedMeanwhile(t *testing.T) {
	const sessionID = "qm-title-race"
	store := newTitledAgentSession(t, sessionID)
	client := &titleRaceTmux{tmuxEnvStub: &tmuxEnvStub{}}
	renamed := make(chan error, 1)
	client.onFirstWrite = func() {
		go func() {
			err := store.Update(sessionID, func(m *state.Manifest) {
				m.Title = "Explicit title"
				m.SetExtra("title_locked", "1")
			})
			if err == nil {
				client.recordTitle("Explicit title")
			}
			renamed <- err
		}()
		select {
		case err := <-renamed:
			renamed <- err
		case <-time.After(time.Second):
			t.Errorf("an explicit rename could not commit while the derived title was written to the pane")
		}
	}
	r, _ := newTestRunner(t)
	r.Store = store
	r.TmuxClient = client

	var stderr bytes.Buffer
	maybeDeriveTitle(t.Context(), r, sessionID, "Derived title", &stderr)
	if err := <-renamed; err != nil {
		t.Fatalf("rename: %v", err)
	}
	if stderr.Len() != 0 {
		t.Fatalf("hook stderr = %q", stderr.String())
	}
	if got := client.lastTitle(); got != "Explicit title" {
		t.Fatalf("final pane title = %q (writes %q), want the explicit title", got, client.titles)
	}
}

// A pane-title write that hangs in tmux must not hold other manifest writers.
func TestDerivedTitlePaneWriteDoesNotHoldTheManifestLock(t *testing.T) {
	const sessionID = "qm-title-blocked"
	store := newTitledAgentSession(t, sessionID)
	entered, release := make(chan struct{}), make(chan struct{})
	client := &titleRaceTmux{tmuxEnvStub: &tmuxEnvStub{}, onFirstWrite: func() {
		close(entered)
		<-release
	}}
	r, _ := newTestRunner(t)
	r.Store = store
	r.TmuxClient = client

	derived := make(chan struct{})
	go func() {
		maybeDeriveTitle(t.Context(), r, sessionID, "Derived title", io.Discard)
		close(derived)
	}()
	<-entered
	updated := make(chan error, 1)
	go func() { updated <- store.Update(sessionID, func(m *state.Manifest) { m.SetExtra("probe", "1") }) }()
	select {
	case err := <-updated:
		if err != nil {
			t.Fatalf("manifest update: %v", err)
		}
	case <-time.After(time.Second):
		t.Errorf("a manifest update waited for a blocked pane-title write")
		close(release)
		<-updated
		<-derived
		return
	}
	close(release)
	<-derived
}
