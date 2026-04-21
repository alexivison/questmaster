package sessionactivity

import (
	"path/filepath"
	"sync"
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

func TestSaveConcurrentWriters(t *testing.T) {
	t.Parallel()

	const writers = 16
	const iterations = 40

	path := filepath.Join(t.TempDir(), "activity.json")
	errCh := make(chan error, writers*iterations)

	var wg sync.WaitGroup
	for i := 0; i < writers; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				state := State{
					Entries: map[string]Entry{
						PrimaryKey("party-concurrent"): {
							SnippetHash:  uint64(i*iterations + j + 1),
							LastChangeAt: time.Unix(int64(i*iterations+j+1), 0).UTC(),
						},
					},
				}
				errCh <- Save(path, state)
			}
		}()
	}

	wg.Wait()
	close(errCh)

	for err := range errCh {
		if err != nil {
			t.Fatalf("Save returned error under concurrent writes: %v", err)
		}
	}

	state, err := Load(path)
	if err != nil {
		t.Fatalf("Load final state: %v", err)
	}
	if len(state.Entries) != 1 {
		t.Fatalf("final state entry count: got %d, want 1", len(state.Entries))
	}
}
