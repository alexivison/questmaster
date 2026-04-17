package tmux

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/charmbracelet/x/ansi"
)

// Capture returns the last N lines of a pane's scrollback buffer.
func (c *Client) Capture(ctx context.Context, target string, lines int) (string, error) {
	if lines <= 0 {
		return "", fmt.Errorf("capture: lines must be positive, got %d", lines)
	}
	out, err := c.runner.Run(ctx,
		"capture-pane", "-t", target, "-p", "-S", "-"+strconv.Itoa(lines),
	)
	if err != nil {
		return "", fmt.Errorf("capture pane %s: %w", target, err)
	}
	return out, nil
}

// IsProgressLine reports whether a cleaned pane line is a live-progress
// status line from Claude or Codex. The spinner glyph on these lines
// animates (Claude cycles `· ✻ ✽ ✶ ✳ ✢`), so we match on the distinctive
// trailing text instead of the leading char. The "esc to interrupt" / "esc
// to clear" phrase is the reliable universal signal (both agents emit it
// only during active generation); "thinking with" is a Claude-specific
// supplement that appears during ER/effort turns.
func IsProgressLine(clean string) bool {
	return strings.Contains(clean, "esc to interrupt") ||
		strings.Contains(clean, "esc to clear") ||
		strings.Contains(clean, "thinking with")
}

// FilterAgentLines extracts the last max meaningful lines from captured pane
// output: ❯/⏺/⎿-prefixed lines, plus live-progress status lines detected by
// IsProgressLine (so Claude's "✳ Lollygagging… (…tokens · thinking with high
// effort)" is surfaced regardless of which spinner frame is current).
// Continuation lines after ⎿ (indented, no prefix) are included to preserve
// full tool results. Returns a slice of cleaned lines.
func FilterAgentLines(raw string, max int) []string {
	var filtered []string
	inResult := false // inside a ⎿ block
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		clean := ansi.Strip(trimmed)
		switch {
		case strings.HasPrefix(clean, "❯") || strings.HasPrefix(clean, "⏺") || strings.HasPrefix(clean, "⎿"):
			if clean == "❯" || clean == "⏺" || clean == "⎿" {
				inResult = false
				continue
			}
			inResult = strings.HasPrefix(clean, "⎿")
			filtered = append(filtered, clean)
		case IsProgressLine(clean):
			inResult = false
			filtered = append(filtered, clean)
		case inResult && clean != "":
			filtered = append(filtered, clean)
		default:
			inResult = false
		}
	}
	if len(filtered) > max {
		filtered = filtered[len(filtered)-max:]
	}
	return filtered
}

// FilterWizardLines extracts the last max meaningful lines from Wizard
// (Codex CLI) pane output. Accepts ❯, ⏺, ⎿, and • prefixed lines — the
// bullet marker is specific to Codex output and kept separate from
// FilterAgentLines to avoid widening Claude-pane previews.
// Continuation lines after ⎿ are included (same logic as FilterAgentLines).
func FilterWizardLines(raw string, max int) []string {
	var filtered []string
	inResult := false
	for _, line := range strings.Split(raw, "\n") {
		clean := ansi.Strip(strings.TrimSpace(line))
		if strings.HasPrefix(clean, "❯") || strings.HasPrefix(clean, "⏺") || strings.HasPrefix(clean, "⎿") || strings.HasPrefix(clean, "•") {
			if clean == "❯" || clean == "⏺" || clean == "⎿" || clean == "•" {
				inResult = false
				continue
			}
			inResult = strings.HasPrefix(clean, "⎿")
			filtered = append(filtered, clean)
		} else if inResult && clean != "" {
			filtered = append(filtered, clean)
		} else {
			inResult = false
		}
	}
	if len(filtered) > max {
		filtered = filtered[len(filtered)-max:]
	}
	return filtered
}
