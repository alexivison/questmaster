//go:build linux || darwin

package state

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestChooseSessionClass(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		active      []string
		index       int
		want        string
		wantChoices int
	}{
		{name: "empty", index: 2, want: "druid", wantChoices: 7},
		{name: "partial unused first", active: []string{"paladin", "paladin", "wizard"}, index: 1, want: "barbarian", wantChoices: 5},
		{name: "all used", active: []string{"paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard", "paladin"}, index: 2, want: "barbarian", wantChoices: 6},
		{name: "lowest count tie", active: []string{"paladin", "paladin", "wizard", "druid", "barbarian", "barbarian", "rogue", "rogue", "cleric", "cleric", "bard", "bard"}, index: 1, want: "druid", wantChoices: 2},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := ChooseSessionClass(tt.active, func(n int) int {
				if n != tt.wantChoices {
					t.Fatalf("random choice count = %d, want %d", n, tt.wantChoices)
				}
				return tt.index
			})
			if got != tt.want {
				t.Fatalf("ChooseSessionClass() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestValidateSessionClass(t *testing.T) {
	t.Parallel()

	want := []string{"paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard"}
	for _, class := range want {
		if got, err := ValidateSessionClass(class); err != nil || got != class {
			t.Fatalf("ValidateSessionClass(%q) = %q, %v", class, got, err)
		}
	}
	if got, err := ValidateSessionClass(" Wizard "); err != nil || got != "wizard" {
		t.Fatalf("ValidateSessionClass() = %q, %v; want wizard", got, err)
	}
	if _, err := ValidateSessionClass("ranger"); err == nil || !strings.Contains(err.Error(), strings.Join(want, ", ")) {
		t.Fatalf("ValidateSessionClass(ranger) error = %v, want valid ids", err)
	}
}

func TestStoreSetSessionClassOnlyAllowsMasters(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name        string
		manifest    Manifest
		class       string
		wantClass   string
		wantErrPart string
	}{
		{
			name: "master",
			manifest: Manifest{SessionID: "qm-master", Agents: []AgentManifest{{Name: "codex", Role: "primary"}}, Display: &DisplayMetadata{
				Color: "violet",
				Extra: map[string]json.RawMessage{"future": json.RawMessage(`true`)},
			}},
			class: " ROGUE ", wantClass: "rogue",
		},
		{name: "worker", manifest: Manifest{SessionID: "qm-worker", Agents: []AgentManifest{{Name: "codex", Role: "primary"}}, Extra: map[string]json.RawMessage{"parent_session": json.RawMessage(`"qm-master"`)}}, class: "bard", wantErrPart: "workers inherit"},
		{name: "shell", manifest: Manifest{SessionID: "qm-shell"}, class: "bard", wantErrPart: "shell sessions"},
		{name: "invalid class", manifest: Manifest{SessionID: "qm-invalid", Agents: []AgentManifest{{Name: "codex", Role: "primary"}}}, class: "ranger", wantErrPart: "paladin, wizard, druid, barbarian, rogue, cleric, bard"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			store, err := NewStore(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			if err := store.Create(tt.manifest); err != nil {
				t.Fatal(err)
			}
			err = store.SetSessionClass(tt.manifest.SessionID, tt.class)
			if tt.wantErrPart != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErrPart) {
					t.Fatalf("SetSessionClass() error = %v, want %q", err, tt.wantErrPart)
				}
				return
			}
			if err != nil {
				t.Fatalf("SetSessionClass(): %v", err)
			}
			got, err := store.Read(tt.manifest.SessionID)
			if err != nil {
				t.Fatal(err)
			}
			if got.DisplayClass() != tt.wantClass {
				t.Fatalf("DisplayClass() = %q, want %q", got.DisplayClass(), tt.wantClass)
			}
			if got.Display == nil || got.Display.Color != "violet" || string(got.Display.Extra["future"]) != "true" {
				t.Fatalf("display metadata = %#v, want color and unknown key preserved", got.Display)
			}
		})
	}
}
