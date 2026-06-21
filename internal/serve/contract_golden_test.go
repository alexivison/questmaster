//go:build linux || darwin

package serve

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/workspace"
)

var updateContractGoldens = flag.Bool("update", false, "update serve contract golden files")

func TestServeContractGoldens(t *testing.T) {
	for _, fixture := range serveContractFixtures() {
		t.Run(fixture.name, func(t *testing.T) {
			got := marshalContractFixture(t, fixture.value)
			assertContractGolden(t, fixture.name, got)
		})
	}
}

type contractFixture struct {
	name  string
	value any
}

func serveContractFixtures() []contractFixture {
	observedAt := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC)
	since := observedAt.Add(-2 * time.Minute)
	loop := &quest.LoopRuntime{
		SessionID:   "qm-demo",
		Iterations:  2,
		LastVerdict: "fail",
		Phase:       "checking",
	}
	q := quest.Quest{
		ID:      "DEMO-1",
		Title:   "Serve runtime JSON",
		Status:  quest.StatusActive,
		Summary: "Expose derived runtime",
		Date:    "2026-06-19",
		Project: "questmaster",
		Related: []quest.RelatedLink{{
			ID:    "plan",
			Type:  "doc",
			Title: "Implementation plan",
			URL:   "file:///tmp/plan.html",
		}},
		Attachments: []quest.AttachmentRef{{
			ItemID: "item-plan",
			Type:   "html",
			Title:  "Inline plan",
		}},
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:go test ./..."},
			{Name: "reviewed", Type: quest.GateToggle, Checked: true},
		},
		Body: []quest.Block{{
			Type: quest.BlockText,
			ID:   "context",
			Text: "Context block",
		}},
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Author:    "questmaster",
			Body:      "Native viewer needs this shape",
			CreatedAt: observedAt.Format(time.RFC3339),
		}},
	}
	runtime := QuestRuntimeSnapshot{
		Sessions: []string{"qm-demo"},
		SessionDetails: []QuestSessionSnapshot{{
			ID:    "qm-demo",
			Agent: "codex",
			State: "working",
			Since: since,
			Loop:  loop,
		}},
		Adventurers: []QuestSessionSnapshot{{
			ID:    "qm-demo",
			Agent: "codex",
			State: "working",
			Since: since,
			Loop:  loop,
		}},
		Agent:      "codex",
		Gates:      map[string]string{"tests": "fail"},
		GatesAt:    map[string]time.Time{"tests": observedAt.Add(-30 * time.Second)},
		ObservedAt: observedAt,
		Loop:       loop,
	}
	board := BoardSnapshot{
		ObservedAt: observedAt,
		Groups: []BoardGroup{{
			Repo: "questmaster",
			Quests: []BoardQuest{{
				Quest:   q,
				Runtime: runtime,
			}},
		}},
	}
	tracker := TrackerSnapshot{
		ObservedAt: observedAt,
		Current: &CurrentSession{
			ID:          "qm-demo",
			Title:       "Serve runtime JSON",
			SessionType: "standalone",
		},
		Sessions: []SessionSnapshot{{
			ID:             "qm-demo",
			Title:          "Serve runtime JSON",
			Status:         "active",
			State:          "working",
			ElapsedMS:      int64((2 * time.Minute).Milliseconds()),
			ElapsedSince:   &since,
			LatestActivity: "Bash: go test ./...",
			LastKind:       "PreToolUse",
			WorktreePath:   "/tmp/questmaster/worktrees/app-contract",
			PrimaryAgent:   "codex",
			SessionType:    "standalone",
			WorkerCount:    1,
			IsCurrent:      true,
			QuestID:        "DEMO-1",
			QuestTitle:     "Serve runtime JSON",
			QuestLoop:      loop,
			Repo: RepoSnapshot{
				Identity: "/tmp/questmaster/.git",
				Name:     "questmaster",
				Color:    "green",
			},
			DisplayColor: "violet",
		}},
	}
	questPayload := QuestSnapshot{
		Quest:      &q,
		Runtime:    runtime,
		ObservedAt: observedAt,
	}
	items := ItemsSnapshot{
		ObservedAt: observedAt,
		Items: []workspace.ListedItem{{
			Item: workspace.Item{
				ID:        "item-plan",
				Type:      "html",
				Title:     "Inline plan",
				CreatedAt: observedAt.Format(time.RFC3339),
				Artifact:  workspace.Artifact{Inline: "<h1>Plan</h1>"},
			},
			Loose:           false,
			AttachmentCount: 1,
			QuestIDs:        []string{"DEMO-1"},
		}},
	}
	activeItem := ActiveItem{
		ID:      "item-plan",
		Type:    "html",
		Title:   "Inline plan",
		QuestID: "DEMO-1",
		Path:    "/tmp/plan.html",
		HTML:    "<h1>Plan</h1>",
	}
	dirSuggest := picker.DirSuggestions{
		Suggestions: []string{"/tmp/questmaster-app", "/tmp/quest-log"},
		Recents:     []string{"/tmp/questmaster-app"},
	}

	return []contractFixture{
		{name: "board_payload.json", value: board},
		{name: "tracker_payload.json", value: tracker},
		{name: "quest_payload.json", value: questPayload},
		{name: "items_payload.json", value: items},
		{name: "active_item_payload.json", value: activeItem},
		{name: "dir_suggest_payload.json", value: dirSuggest},
		{name: "board_response_envelope.json", value: Envelope{
			Type:  "response",
			ID:    json.RawMessage(`"board-1"`),
			OK:    boolPtr(true),
			Topic: topicBoard,
			Data:  board,
		}},
		{name: "tracker_event_envelope.json", value: Envelope{
			Type:  "event",
			Topic: topicTracker,
			Data:  tracker,
		}},
		{name: "active_item_event_envelope.json", value: Envelope{
			Type:  "event",
			Topic: topicActiveItem,
			Data:  activeItem,
		}},
	}
}

func marshalContractFixture(t *testing.T, value any) []byte {
	t.Helper()

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	if err := enc.Encode(value); err != nil {
		t.Fatalf("marshal contract fixture: %v", err)
	}
	return buf.Bytes()
}

func assertContractGolden(t *testing.T, name string, got []byte) {
	t.Helper()

	path := filepath.Join(contractTestdataDir(t), name)
	if *updateContractGoldens {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("create contract testdata: %v", err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatalf("write contract golden %s: %v", name, err)
		}
		return
	}

	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read contract golden %s: %v (run go test -buildvcs=false ./internal/serve -update)", name, err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("contract golden %s changed\nwant:\n%s\ngot:\n%s", name, want, got)
	}
}

func contractTestdataDir(t *testing.T) string {
	t.Helper()

	abs, err := filepath.Abs(filepath.Join("..", "..", "contract", "testdata"))
	if err != nil {
		t.Fatalf("resolve contract testdata dir: %v", err)
	}
	return abs
}
