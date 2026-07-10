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

	"github.com/alexivison/questmaster/internal/dirsuggest"
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

func TestWriteEnvelopeStampsProtocolVersion(t *testing.T) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	if err := writeEnvelope(enc, Envelope{Type: "event", Topic: topicTracker, Data: TrackerSnapshot{}}); err != nil {
		t.Fatalf("write envelope: %v", err)
	}

	var env Envelope
	if err := json.Unmarshal(buf.Bytes(), &env); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if env.ProtocolVersion != ServeProtocolVersion {
		t.Fatalf("protocol version = %d, want %d", env.ProtocolVersion, ServeProtocolVersion)
	}
}

type contractFixture struct {
	name  string
	value any
}

func serveContractFixtures() []contractFixture {
	observedAt := time.Date(2026, 6, 19, 4, 20, 0, 0, time.UTC)
	since := observedAt.Add(-2 * time.Minute)
	artifact := ArtifactSnapshot{
		Kind:      "html",
		Path:      "/tmp/questmaster/worktrees/app-contract/docs/plan.html",
		Label:     "Plan",
		SessionID: "qm-demo",
		ProjectID: "/tmp/questmaster/.git",
		AddedAt:   observedAt.Add(-time.Minute).Format(time.RFC3339),
		Missing:   true,
	}
	markdownArtifact := ArtifactSnapshot{
		Kind:      "markdown",
		Path:      "/tmp/questmaster/worktrees/app-contract/docs/report.md",
		Label:     "Report",
		SessionID: "qm-demo",
		ProjectID: "/tmp/questmaster/.git",
		AddedAt:   observedAt.Add(-30 * time.Second).Format(time.RFC3339),
	}
	imageArtifact := ArtifactSnapshot{
		Kind:      "image",
		Path:      "/tmp/questmaster/worktrees/app-contract/docs/screenshot.png",
		Label:     "Screenshot",
		SessionID: "qm-demo",
		ProjectID: "/tmp/questmaster/.git",
		AddedAt:   observedAt.Add(-20 * time.Second).Format(time.RFC3339),
	}
	orphanArtifact := ArtifactSnapshot{
		Kind:      "html",
		Path:      "/tmp/questmaster/old-sessions/qm-orphan/docs/orphan.html",
		Label:     "Orphan",
		SessionID: "qm-orphan",
		ProjectID: "/tmp/questmaster/.git",
		AddedAt:   observedAt.Add(-10 * time.Second).Format(time.RFC3339),
	}
	activeQuest := QuestSnapshot{
		ID:          "qst-1781842800",
		Content:     "Add --search flag to qm quest ls",
		ProjectID:   "/tmp/questmaster/.git",
		ProjectPath: "/tmp/questmaster/worktrees/app-contract",
		ProjectName: "questmaster",
		CreatedAt:   observedAt.Add(-3 * time.Minute).Format(time.RFC3339),
		UpdatedAt:   observedAt.Add(-3 * time.Minute).Format(time.RFC3339),
		SessionID:   "qm-demo",
	}
	secondQuest := QuestSnapshot{
		ID:          "qst-1781842860",
		Content:     "Archive stale artifact notes",
		ProjectID:   "/tmp/questmaster/.git",
		ProjectPath: "/tmp/questmaster/worktrees/app-contract",
		ProjectName: "questmaster",
		CreatedAt:   observedAt.Add(-2 * time.Minute).Format(time.RFC3339),
		UpdatedAt:   observedAt.Add(-time.Minute).Format(time.RFC3339),
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
			Artifacts:      []ArtifactSnapshot{artifact, markdownArtifact, imageArtifact},
			Repo: RepoSnapshot{
				Identity: "/tmp/questmaster/.git",
				Name:     "questmaster",
				Color:    "green",
			},
			DisplayColor: "violet",
		}},
		Projects: []ProjectSnapshot{{
			ID:    "/tmp/questmaster/.git",
			Name:  "questmaster",
			Path:  "/tmp/questmaster",
			Color: "green",
		}},
		Artifacts: []ArtifactSnapshot{artifact, markdownArtifact, imageArtifact, orphanArtifact},
		Quests:    []QuestSnapshot{activeQuest, secondQuest},
	}
	dirSuggest := dirsuggest.Suggestions{
		Suggestions: []string{"/tmp/project-app", "/tmp/project-log"},
		Recents:     []string{"/tmp/project-app"},
	}

	return []contractFixture{
		{name: "tracker_payload.json", value: tracker},
		{name: "dir_suggest_payload.json", value: dirSuggest},
		{name: "tracker_event_envelope.json", value: Envelope{
			ProtocolVersion: ServeProtocolVersion,
			Type:            "event",
			Topic:           topicTracker,
			Data:            tracker,
		}},
		{name: "tracker_response_envelope.json", value: Envelope{
			ProtocolVersion: ServeProtocolVersion,
			Type:            "response",
			ID:              json.RawMessage(`"tracker-request"`),
			OK:              boolPtr(true),
			Topic:           topicTracker,
			Data:            tracker,
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

	abs, err := filepath.Abs("testdata")
	if err != nil {
		t.Fatalf("resolve contract testdata dir: %v", err)
	}
	return abs
}
