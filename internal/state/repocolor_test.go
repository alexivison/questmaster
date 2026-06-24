//go:build linux || darwin

package state

import (
	"os"
	"testing"
	"time"
)

func TestRepoColorStoreRoundTrip(t *testing.T) {
	t.Parallel()

	store := NewRepoColorStore(t.TempDir())

	if err := store.Set("/repos/a/.git", "green"); err != nil {
		t.Fatalf("set: %v", err)
	}
	rc, ok, err := store.Get("/repos/a/.git")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !ok {
		t.Fatal("expected color set")
	}
	if rc.Color != "green" {
		t.Fatalf("color = %q, want green", rc.Color)
	}
	if ParseColorStamp(rc.UpdatedAt).IsZero() {
		t.Fatalf("UpdatedAt = %q, want a real timestamp", rc.UpdatedAt)
	}
}

func TestRepoColorStorePersistsAcrossInstances(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	if err := NewRepoColorStore(root).Set("/repos/b/.git", "red"); err != nil {
		t.Fatalf("set: %v", err)
	}

	// A fresh store (simulating a tracker restart) sees the persisted color.
	rc, ok, err := NewRepoColorStore(root).Get("/repos/b/.git")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if !ok || rc.Color != "red" {
		t.Fatalf("reloaded color = %q ok=%v, want red", rc.Color, ok)
	}
}

func TestRepoColorStoreEmptyColorClears(t *testing.T) {
	t.Parallel()

	store := NewRepoColorStore(t.TempDir())
	if err := store.Set("/repos/c/.git", "cyan"); err != nil {
		t.Fatalf("set: %v", err)
	}
	if err := store.Set("/repos/c/.git", ""); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if _, ok, err := store.Get("/repos/c/.git"); err != nil || ok {
		t.Fatalf("after clear: ok=%v err=%v, want cleared", ok, err)
	}
}

func TestRepoColorStoreEmptyIdentityIsNoOp(t *testing.T) {
	t.Parallel()

	store := NewRepoColorStore(t.TempDir())
	if err := store.Set("", "green"); err != nil {
		t.Fatalf("set empty identity: %v", err)
	}
	m, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if len(m) != 0 {
		t.Fatalf("store = %v, want empty", m)
	}
}

func TestRepoColorStoreLoadMissingFileIsEmpty(t *testing.T) {
	t.Parallel()

	m, err := NewRepoColorStore(t.TempDir()).Load()
	if err != nil {
		t.Fatalf("load missing: %v", err)
	}
	if len(m) != 0 {
		t.Fatalf("missing-file load = %v, want empty map", m)
	}
}

func TestRepoColorStoreSetResetsCorruptFile(t *testing.T) {
	t.Parallel()

	store := NewRepoColorStore(t.TempDir())
	if err := os.WriteFile(store.path, []byte("{not json"), 0o644); err != nil {
		t.Fatalf("write corrupt repo-colors: %v", err)
	}

	if err := store.Set("/repos/corrupt/.git", "blue"); err != nil {
		t.Fatalf("set after corrupt file: %v", err)
	}

	rc, ok, err := store.Get("/repos/corrupt/.git")
	if err != nil {
		t.Fatalf("get after reset: %v", err)
	}
	if !ok || rc.Color != "blue" {
		t.Fatalf("color after reset = %q ok=%v, want blue", rc.Color, ok)
	}
}

// TestEffectiveColorLastWriteWins walks the five acceptance scenarios from the
// quest, driving them purely through timestamps.
func TestEffectiveColorLastWriteWins(t *testing.T) {
	t.Parallel()

	base := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	t1 := base                      // repo recolored red
	t2 := base.Add(1 * time.Minute) // session A recolored blue
	t3 := base.Add(2 * time.Minute) // repo recolored green
	zero := time.Time{}

	cases := map[string]struct {
		ownColor  string
		ownAt     time.Time
		repoColor string
		repoAt    time.Time
		want      string
	}{
		"1: repo red, session unset -> red":              {"", zero, "red", t1, "red"},
		"2a: session A blue after repo red -> blue":      {"blue", t2, "red", t1, "blue"},
		"2b: sibling unset under repo red -> red":        {"", zero, "red", t1, "red"},
		"3: repo green newest beats session blue":        {"blue", t2, "green", t3, "green"},
		"4: new session unset under repo green -> green": {"", zero, "green", t3, "green"},
		"5a: repo cleared, session keeps own blue":       {"blue", t2, "", zero, "blue"},
		"5b: repo cleared, no own color -> default":      {"", zero, "", zero, ""},
	}
	for name, c := range cases {
		c := c
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := EffectiveColor(c.ownColor, c.ownAt, c.repoColor, c.repoAt); got != c.want {
				t.Fatalf("EffectiveColor = %q, want %q", got, c.want)
			}
		})
	}
}

func TestEffectiveColorTieKeepsOwn(t *testing.T) {
	t.Parallel()

	at := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	if got := EffectiveColor("blue", at, "red", at); got != "blue" {
		t.Fatalf("tie should keep own color, got %q", got)
	}
}
