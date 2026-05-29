package cmd

import "testing"

// startThenPrompt drives the SessionStart → first-prompt sequence that the
// title heuristic keys off of. rec.lastState persists between the two calls,
// so the second call sees the pane still in its "starting" state.
func TestHookClaudeDerivesTitleOnFirstPrompt(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "investigate the flaky test" {
		t.Fatalf("title = %q, want %q", store.manifest.Title, "investigate the flaky test")
	}
}

func TestHookClaudeDoesNotDeriveTitleMidConversation(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	// A "working" action without a preceding "starting" is not a first turn;
	// the title must stay blank.
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "some later message"})

	if store.manifest.Title != "" {
		t.Fatalf("title = %q, want blank (mid-conversation turn)", store.manifest.Title)
	}
}

func TestHookDoesNotOverwriteExistingTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	store.manifest.Title = "deliberate name"
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "deliberate name" {
		t.Fatalf("title = %q, want unchanged %q", store.manifest.Title, "deliberate name")
	}
}

func TestHookRespectsLockedTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", map[string]string{"title_locked": "1"})
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	runHookWithStdin(r, "claude", "starting", "qm-t", map[string]interface{}{"session_id": "s1"})
	runHookWithStdin(r, "claude", "working", "qm-t", map[string]interface{}{"prompt": "investigate the flaky test"})

	if store.manifest.Title != "" {
		t.Fatalf("title = %q, want blank (locked)", store.manifest.Title)
	}
}

func TestHookCodexDerivesTitleOnFirstPrompt(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	runHookWithStdin(r, "codex", "starting", "qm-t", nil)
	runHookWithStdin(r, "codex", "working", "qm-t", map[string]interface{}{"prompt": "add a retry to the uploader"})

	if store.manifest.Title != "add a retry to the uploader" {
		t.Fatalf("title = %q, want %q", store.manifest.Title, "add a retry to the uploader")
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
