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

// FilterAgentLines extracts the last max meaningful lines (❯, ⏺, or ⎿ prefixed)
// from captured pane output. Returns a slice of trimmed lines.
func FilterAgentLines(raw string, max int) []string {
	var filtered []string
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		// Strip ANSI escape codes so raw terminal colours don't
		// corrupt the lipgloss-rendered tracker display.
		clean := ansi.Strip(trimmed)
		if strings.HasPrefix(clean, "❯") || strings.HasPrefix(clean, "⏺") || strings.HasPrefix(clean, "⎿") {
			if clean == "❯" || clean == "⏺" || clean == "⎿" {
				continue
			}
			filtered = append(filtered, clean)
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
func FilterWizardLines(raw string, max int) []string {
	var filtered []string
	for _, line := range strings.Split(raw, "\n") {
		clean := ansi.Strip(strings.TrimSpace(line))
		if strings.HasPrefix(clean, "❯") || strings.HasPrefix(clean, "⏺") || strings.HasPrefix(clean, "⎿") || strings.HasPrefix(clean, "•") {
			if clean == "❯" || clean == "⏺" || clean == "⎿" || clean == "•" {
				continue
			}
			filtered = append(filtered, clean)
		}
	}
	if len(filtered) > max {
		filtered = filtered[len(filtered)-max:]
	}
	return filtered
}
