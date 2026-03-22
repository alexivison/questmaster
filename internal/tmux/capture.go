package tmux

import (
	"context"
	"fmt"
	"strconv"
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
