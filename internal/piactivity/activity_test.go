package piactivity

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func writeSidecar(t *testing.T, sessionID string, state State) {
	t.Helper()
	path := Path(sessionID)
	if path == "" {
		t.Fatalf("invalid sidecar path for %q", sessionID)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir sidecar dir: %v", err)
	}
	data, err := json.Marshal(state)
	if err != nil {
		t.Fatalf("marshal sidecar: %v", err)
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		t.Fatalf("write sidecar: %v", err)
	}
}

func TestReadFreshSidecar(t *testing.T) {
	now := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)
	sessionID := "party-piactivity-fresh"
	writeSidecar(t, sessionID, State{
		Version:     1,
		Source:      "pi",
		ID:          sessionID,
		UpdatedAtMS: now.Add(-time.Second).UnixMilli(),
		Busy:        true,
		Phase:       "tool",
		Snippet:     " running tests ",
		Recent:      []string{"", " read file ", "running tests"},
	})

	got, ok := Read(sessionID, now)
	if !ok {
		t.Fatal("expected fresh sidecar")
	}
	if !got.Busy || got.Phase != "tool" || got.Snippet != "running tests" {
		t.Fatalf("unexpected snapshot: %+v", got)
	}
	if want := []string{"read file", "running tests"}; !reflect.DeepEqual(got.Recent, want) {
		t.Fatalf("recent = %#v, want %#v", got.Recent, want)
	}
}

func TestReadRejectsStaleAndMismatchedSidecars(t *testing.T) {
	now := time.Date(2026, time.May, 7, 12, 0, 0, 0, time.UTC)

	staleID := "party-piactivity-stale"
	writeSidecar(t, staleID, State{
		Version:     1,
		Source:      "pi",
		ID:          staleID,
		UpdatedAtMS: now.Add(-MaxAge - time.Second).UnixMilli(),
		Busy:        true,
	})
	if _, ok := Read(staleID, now); ok {
		t.Fatal("expected stale sidecar to be rejected")
	}
	if latest, ok := ReadLatest(staleID); !ok || !latest.Busy {
		t.Fatalf("expected stale sidecar to remain available as latest snapshot, got %+v ok=%v", latest, ok)
	}

	mismatchID := "party-piactivity-mismatch"
	writeSidecar(t, mismatchID, State{
		Version:     1,
		Source:      "pi",
		ID:          "party-other",
		UpdatedAtMS: now.UnixMilli(),
		Busy:        true,
	})
	if _, ok := Read(mismatchID, now); ok {
		t.Fatal("expected mismatched sidecar to be rejected")
	}
}

func TestPathRejectsInvalidPartyID(t *testing.T) {
	if got := Path("../../escape"); got != "" {
		t.Fatalf("Path accepted invalid id: %q", got)
	}
}
