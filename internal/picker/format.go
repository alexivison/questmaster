package picker

import (
	"strings"
)

// Layout constants for entry rows.
const (
	// minTitleColW is the smallest title column a row keeps before it drops
	// the right-aligned metadata to give the title more room.
	minTitleColW = 8
)

// truncStr truncates a string to max runes, appending "…" if needed.
func truncStr(s string, max int) string {
	if len(s) <= max {
		return s
	}
	if max <= 1 {
		return "…"
	}
	return s[:max-1] + "…"
}

// padRight pads a string with spaces to the given width.
func padRight(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return s + strings.Repeat(" ", width-len(s))
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
