// Package palette shares Questmaster's sRGB colours with tmux and the app.
package palette

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"
)

//go:generate go run ./generate

//go:embed palette.json
var source []byte

type State struct {
	Name        string `json:"name"`
	Hex         string `json:"hex"`
	Description string `json:"description"`
}

type Palette struct {
	Colors  map[string]string `json:"colors"`
	States  []State           `json:"states"`
	Display map[string]string `json:"display"`
}

// Source returns a fresh copy of the canonical palette for code generation.
func Source() Palette {
	var p Palette
	if err := json.Unmarshal(source, &p); err != nil {
		panic(fmt.Errorf("decode built-in palette: %w", err))
	}
	return p
}

var builtin = Source()

// Colors returns all semantic colours, including interaction states.
func Colors() map[string]string {
	colors := make(map[string]string, len(builtin.Colors)+len(builtin.States))
	for name, hex := range builtin.Colors {
		colors[name] = hex
	}
	for _, state := range builtin.States {
		colors[state.Name] = state.Hex
	}
	return colors
}

// Display resolves a named session colour. Unset sessions use body text,
// matching the app's uncoloured plates; "none" is the explicit inert colour.
func Display(name string) string {
	if hex, ok := builtin.Display[strings.ToLower(strings.TrimSpace(name))]; ok {
		return hex
	}
	return Colors()["textBody"]
}
