package board

import (
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// TestFrameCacheServesUnchangedAndBustsOnChange asserts the View frame cache
// returns a stable frame for unchanged state and recomputes when the view-state
// changes (B1). It also confirms a cached frame equals a fresh render.
func TestFrameCacheServesUnchangedAndBustsOnChange(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "ACT-2", quest.StatusActive)
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 30

	first := m.View()
	if !m.frame.valid {
		t.Fatal("View did not populate the frame cache")
	}
	if first != m.renderFrame() {
		t.Fatal("cached frame differs from a fresh render")
	}
	keyBefore := m.frame.key

	// A no-op message (same state) must serve the cache without changing the key.
	again := m.View()
	if again != first || m.frame.key != keyBefore {
		t.Fatal("identical state did not hit the frame cache")
	}

	// Moving the cursor changes view-state: the key must change and the frame
	// must be recomputed (different selection highlight).
	m, _ = update(m, key("j"))
	moved := m.View()
	if m.frame.key == keyBefore {
		t.Fatal("cursor move did not change the frame cache key")
	}
	if moved == first {
		t.Fatal("cursor move produced an identical frame (highlight did not move)")
	}
}

// TestReloadGatesOnFingerprint asserts the parse-skipping behaviour (B2): a tick
// with nothing changed on disk leaves contentVersion (and therefore the frame
// cache) untouched, while an external write bumps it.
func TestReloadGatesOnFingerprint(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})

	v0 := m.contentVersion
	m, _ = update(m, tickMsg(time.Now())) // no disk change
	if m.contentVersion != v0 {
		t.Fatalf("idle tick bumped contentVersion %d -> %d; cache would needlessly invalidate", v0, m.contentVersion)
	}

	save(t, s, "ACT-2", quest.StatusActive) // external write
	m, _ = update(m, tickMsg(time.Now()))
	if m.contentVersion == v0 {
		t.Fatal("contentVersion did not bump after an on-disk change")
	}
	if len(m.visible) != 2 {
		t.Fatalf("reload after change saw %d quests, want 2", len(m.visible))
	}
}

// TestLiveRuntimeBumpsVersionEachTick asserts that when a quest has live runtime
// (an attached working session), the version bumps every tick even with no disk
// change, so durations/verdict ages stay fresh instead of freezing behind the
// frame cache.
func TestLiveRuntimeBumpsVersionEachTick(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	rt := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{
			"ACT-1": {
				Sessions:    []string{"qm-1"},
				Adventurers: []quest.Adventurer{{ID: "qm-1", Agent: "claude", State: "working"}},
			},
		}
	}
	m := NewModel(s, rt, Commands{})

	v0 := m.contentVersion
	m, _ = update(m, tickMsg(time.Now()))
	if m.contentVersion == v0 {
		t.Fatal("live runtime did not bump contentVersion on a tick; durations would freeze")
	}
}

// TestComposerBypassesFrameCache asserts the composer's live textarea is never
// served from the cache — typing must repaint without a reload.
func TestComposerBypassesFrameCache(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "ui", Type: quest.GateToggle}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{Now: time.Now, Author: func() string { return "me" }})
	m.width, m.height = 100, 30
	m, _ = update(m, key("l")) // focus detail
	m, _ = update(m, key("m")) // open composer
	if m.composer == nil {
		t.Fatal("setup: composer did not open")
	}

	before := m.View()
	m = typeText(m, "hello")
	after := m.View()
	if before == after {
		t.Fatal("composer keystrokes were served stale from the frame cache")
	}
}
