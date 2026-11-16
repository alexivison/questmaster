package palette_test

import (
	"regexp"
	"testing"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
)

func TestPaletteCoversDisplayColours(t *testing.T) {
	t.Parallel()
	p := palette.Source()
	hex := regexp.MustCompile(`^#[0-9a-f]{6}$`)
	for _, name := range state.DisplayColorOptions() {
		if !hex.MatchString(p.Display[name]) {
			t.Errorf("display colour %q missing or invalid: %q", name, p.Display[name])
		}
	}
	for name, value := range palette.Colors() {
		if !hex.MatchString(value) {
			t.Errorf("colour %q invalid: %q", name, value)
		}
	}
	if palette.Display("") != palette.Colors()["textBody"] || palette.Display("none") != p.Display["none"] {
		t.Fatal("unset and explicitly neutral colours must match the app's distinct fallbacks")
	}
}
