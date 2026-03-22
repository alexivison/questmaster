package tmux

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// ErrSendTimeout is returned when the pane does not become idle within the send timeout.
var ErrSendTimeout = errors.New("send timeout: pane not idle")

// Send delivers text to a tmux pane with idle-check retry.
// Mirrors party-lib.sh tmux_send: retries until the pane leaves copy mode or timeout.
// Returns a SendResult envelope — callers inspect .Delivered and .Err.
func (c *Client) Send(ctx context.Context, target, text string) SendResult {
	deadline := time.Now().Add(c.SendTimeout)
	for {
		idle, err := c.IsPaneIdle(ctx, target)
		if err != nil {
			return SendResult{Target: target, Err: fmt.Errorf("check idle: %w", err)}
		}
		if idle {
			return c.sendKeys(ctx, target, text)
		}
		if time.Now().After(deadline) {
			return SendResult{Target: target, Err: ErrSendTimeout}
		}

		select {
		case <-ctx.Done():
			return SendResult{Target: target, Err: ctx.Err()}
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// IsPaneIdle checks whether the pane is NOT in copy/choice mode.
func (c *Client) IsPaneIdle(ctx context.Context, target string) (bool, error) {
	out, err := c.runner.Run(ctx, "display-message", "-t", target, "-p", "#{pane_in_mode}")
	if err != nil {
		return false, fmt.Errorf("display-message: %w", err)
	}
	return out == "0", nil
}

// sendKeys sends text literally followed by Enter with an inter-key delay.
// The 100ms delay between text and Enter avoids the Ink paste-mode newline bug
// that the shell transport was hardened against (see party-lib.sh tmux_send).
func (c *Client) sendKeys(ctx context.Context, target, text string) SendResult {
	if _, err := c.runner.Run(ctx, "send-keys", "-t", target, "-l", "--", text); err != nil {
		return SendResult{Target: target, Err: fmt.Errorf("send text: %w", err)}
	}
	select {
	case <-ctx.Done():
		return SendResult{Target: target, Err: ctx.Err()}
	case <-time.After(100 * time.Millisecond):
	}
	if _, err := c.runner.Run(ctx, "send-keys", "-t", target, "Enter"); err != nil {
		return SendResult{Target: target, Err: fmt.Errorf("send enter: %w", err)}
	}
	return SendResult{Delivered: true, Target: target}
}
