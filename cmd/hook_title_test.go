package cmd

import "testing"

// startThenPrompt drives the SessionStart → first-prompt sequence that the
// title heuristic keys off of. rec.lastState persists between the two calls,
// so the second call sees the pane still in its "starting" state.
func TestHookClaudeDerivesTitleOnFirstPrompt(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-t", nil)
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
