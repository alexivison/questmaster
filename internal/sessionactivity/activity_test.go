package sessionactivity

import (
	"testing"
	"time"
)

func TestEvaluateMarksChangedSnippetActive(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 4, 21, 5, 0, 0, 0, time.UTC)
	prev, _ := Evaluate(now.Add(-5*time.Second), []Observation{{
		Key:     PrimaryKey("party-1"),
		Snippet: "⏺ old",
		Enabled: true,
	}}, State{})

	next, results := Evaluate(now, []Observation{{
		Key:     PrimaryKey("party-1"),
		Snippet: "⏺ new",
		Enabled: true,
	}}, prev)

	result := results[PrimaryKey("party-1")]
	if !result.Active {
		t.Fatal("expected changed snippet to be active")
	}
	if got := next.Entries[PrimaryKey("party-1")].LastChangeAt; !got.Equal(now) {
		t.Fatalf("last change: got %v, want %v", got, now)
	}
}

func TestEvaluateExpiresUnchangedSnippetAfterWindow(t *testing.T) {
	t.Parallel()

	now := time.Date(2026, 4, 21, 5, 0, 0, 0, time.UTC)
	prev := State{
		Entries: map[string]Entry{
			PrimaryKey("party-1"): {
				SnippetHash:  HashSnippet("⏺ steady"),
				LastChangeAt: now.Add(-Window - time.Second),
			},
		},
	}

	next, results := Evaluate(now, []Observation{{
		Key:     PrimaryKey("party-1"),
		Snippet: "⏺ steady",
		Enabled: true,
	}}, prev)

	if results[PrimaryKey("party-1")].Active {
		t.Fatal("expected unchanged stale snippet to be inactive")
	}
	if got := next.Entries[PrimaryKey("party-1")].LastChangeAt; !got.Equal(prev.Entries[PrimaryKey("party-1")].LastChangeAt) {
		t.Fatalf("last change should be preserved, got %v want %v", got, prev.Entries[PrimaryKey("party-1")].LastChangeAt)
	}
}
