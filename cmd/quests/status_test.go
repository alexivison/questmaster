package main

import (
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// TestLoadQuestRuntimeOverlaysSessions verifies the Stage-1 quest↔session link:
// a session wearing the quest hat appears in the runtime record's sessions, and
// a draft quest with an attached session reads as in_progress.
func TestLoadQuestRuntimeOverlaysSessions(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	e.spawnSession = fakeSpawn(e, nil, nil)

	if _, err := runQuest(t, e, "quest", "new", "ENG-1", "--goal", "g"); err != nil {
		t.Fatalf("quest new: %v", err)
	}
	if _, err := runQuest(t, e, "session", "new", "work", "--quest", "ENG-1"); err != nil {
		t.Fatalf("session new --quest: %v", err)
	}

	rec, err := e.loadQuestRuntime("ENG-1")
	if err != nil {
		t.Fatalf("loadQuestRuntime: %v", err)
	}
	if len(rec.Sessions) != 1 {
		t.Fatalf("overlay sessions = %d, want 1", len(rec.Sessions))
	}
	if rec.Status != runtime.StatusInProgress {
		t.Errorf("status = %q, want in_progress (a session is attached)", rec.Status)
	}
}

func TestStatusBannerContents(t *testing.T) {
	q := quest.Quest{
		ID:   "ENG-1",
		Goal: "g",
		Gates: []quest.Gate{
			{Name: "ci", Type: quest.GateAuto, Check: "github:checks"},
			{Name: "ui", Type: quest.GateToggle},
		},
	}
	rec := &runtime.RuntimeRecord{
		Status:      runtime.StatusInProgress,
		GateResults: map[string]string{"ci": "green"},
		Sessions:    []runtime.SessionRef{{ID: "qm-1", Agent: "claude", State: "working"}},
		PR:          &runtime.PRStatus{Number: 441},
	}
	banner := statusBanner(q, rec)
	for _, want := range []string{"live ▾", "in_progress", "ci", "ui", "claude", "PR #441"} {
		if !strings.Contains(banner, want) {
			t.Errorf("banner missing %q\n%s", want, banner)
		}
	}
}

func TestInjectBannerAfterBody(t *testing.T) {
	body := []byte("<html><body><h1>hi</h1></body></html>")
	out := string(injectBanner(body, "<div>BANNER</div>"))
	bodyIdx := strings.Index(out, "<body>")
	bannerIdx := strings.Index(out, "BANNER")
	h1Idx := strings.Index(out, "<h1>")
	if !(bodyIdx < bannerIdx && bannerIdx < h1Idx) {
		t.Errorf("banner should be injected right after <body>, before content:\n%s", out)
	}
}

func TestInjectBannerNoBodyPrepends(t *testing.T) {
	out := string(injectBanner([]byte("<p>x</p>"), "<div>B</div>"))
	if !strings.HasPrefix(out, "<div>B</div>") {
		t.Errorf("with no <body>, banner should prepend: %q", out)
	}
}
