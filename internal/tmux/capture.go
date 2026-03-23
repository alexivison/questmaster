package tmux

import (
	"context"
	"fmt"
	"strconv"
	"strings"
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

// FilterAgentLines extracts the last max meaningful lines (❯ or ⏺ prefixed)
// from captured pane output. Returns a slice of trimmed lines.
func FilterAgentLines(raw string, max int) []string {
	var filtered []string
	for _, line := range strings.Split(raw, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(line, "❯") || strings.HasPrefix(line, "⏺") {
			if trimmed == "❯" || trimmed == "⏺" {
				continue
			}
			filtered = append(filtered, trimmed)
		}
	}
	if len(filtered) > max {
		filtered = filtered[len(filtered)-max:]
	}
	return filtered
}
