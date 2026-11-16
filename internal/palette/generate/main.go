// Command generate emits the Swift palette from the shared JSON source.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexivison/questmaster/internal/palette"
)

func main() {
	path := filepath.Join("..", "..", "app", "Sources", "Core", "Rendering", "ThemePalette.swift")
	if err := os.WriteFile(path, []byte(render()), 0o644); err != nil {
		panic(err)
	}
}

func render() string {
	p := palette.Source()
	var out strings.Builder
	out.WriteString("// Generated from internal/palette/palette.json by go generate ./internal/palette.\n// Do not edit; update the JSON and regenerate.\n\n")
	out.WriteString("/// Shared sRGB colours used by the app and tmux.\npublic enum ThemePalette {\n")
	for _, name := range sortedKeys(p.Colors) {
		fmt.Fprintf(&out, "    public static let %s: UInt32 = 0x%s\n", name, strings.TrimPrefix(p.Colors[name], "#"))
	}
	out.WriteString("\n    public static let displayColors: [String: UInt32] = [\n")
	for _, name := range sortedKeys(p.Display) {
		fmt.Fprintf(&out, "        %q: 0x%s,\n", name, strings.TrimPrefix(p.Display[name], "#"))
	}
	out.WriteString("    ]\n}\n\n/// The colours used by interaction-state looks.\npublic enum StateColor: UInt32, CaseIterable, Sendable {\n")
	for _, state := range p.States {
		for _, line := range strings.Split(state.Description, "\n") {
			fmt.Fprintf(&out, "    /// %s\n", line)
		}
		fmt.Fprintf(&out, "    case %s = 0x%s\n", state.Name, strings.TrimPrefix(state.Hex, "#"))
	}
	out.WriteString("}\n")
	return out.String()
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
