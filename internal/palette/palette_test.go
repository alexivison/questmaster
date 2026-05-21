package palette

import (
	"strings"
	"testing"
)

func TestPaletteUsesANSIIndexes(t *testing.T) {
	t.Parallel()

	// Agent-identity colors (ClaudeColor / CodexColor / PiColor) and
	// SelectedRowBg are intentionally truecolor; everything else inherits the
	// terminal palette so themes can recolor freely.
	cases := map[string]string{
		"Added":                 string(Added),
		"Deleted":               string(Deleted),
		"HunkHeader":            string(HunkHeader),
		"Clean":                 string(Clean),
		"Warn":                  string(Warn),
		"Error":                 string(Error),
		"Accent":                string(Accent),
		"Muted":                 string(Muted),
		"StatusBg":              string(StatusBg),
		"StatusFg":              string(StatusFg),
		"DividerFg":             string(DividerFg),
		"BrightText":            string(BrightText),
		"MasterRole":            string(MasterRole),
		"WorkerRole":            string(WorkerRole),
		"StandaloneRole":        string(StandaloneRole),
		"TmuxRole":              string(TmuxRole),
		"OrphanRole":            string(OrphanRole),
		"DividerBorder":         string(DividerBorder),
		"PickerVerticalDivider": string(PickerVerticalDivider),
		"SelectedBoxBorder":     string(SelectedBoxBorder),
	}
	for name, value := range cases {
		if strings.HasPrefix(value, "#") {
			t.Fatalf("%s should use ANSI palette index, got hex %q", name, value)
		}
	}
}

func TestSelectedRowBgIsTheOnlyNonANSIColor(t *testing.T) {
	t.Parallel()

	if SelectedRowBg.Light != "#eaeef2" || SelectedRowBg.Dark != "#2d333b" {
		t.Fatalf("SelectedRowBg = %#v, want light=#eaeef2 dark=#2d333b", SelectedRowBg)
	}
}

func TestPaletteMappings(t *testing.T) {
	t.Parallel()

	if MasterRole != "11" {
		t.Fatalf("MasterRole = %q, want 11", MasterRole)
	}
	if DividerBorder != Muted {
		t.Fatalf("DividerBorder = %q, want Muted %q", DividerBorder, Muted)
	}
	if WorkerRole != "5" {
		t.Fatalf("WorkerRole = %q, want 5", WorkerRole)
	}
	if ClaudeColor != "#CC785C" {
		t.Fatalf("ClaudeColor = %q, want #CC785C", ClaudeColor)
	}
	if CodexColor != "#1A73E8" {
		t.Fatalf("CodexColor = %q, want #1A73E8", CodexColor)
	}
	if PiColor != "#A371F7" {
		t.Fatalf("PiColor = %q, want #A371F7", PiColor)
	}
}
