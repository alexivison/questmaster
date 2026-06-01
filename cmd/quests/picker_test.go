package main

import (
	"testing"

	"github.com/alexivison/questmaster/internal/picker"
)

// TestPickerRunsWithEmptyStore exercises the quests picker wiring (entries,
// registry, agent options) with the TUI program stubbed out.
func TestPickerRunsWithEmptyStore(t *testing.T) {
	testHome(t)

	orig := runPickerProgram
	defer func() { runPickerProgram = orig }()
	// Stub the TUI: return a model with no selection, so no attach happens.
	runPickerProgram = func(m picker.Model) (picker.Model, error) { return m, nil }

	e := defaultEnv()
	if _, err := runQuest(t, e, "picker"); err != nil {
		t.Fatalf("picker: %v", err)
	}
}
