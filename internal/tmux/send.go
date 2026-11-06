package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// ErrSendTimeout is returned when the pane does not become idle within the send timeout.
var ErrSendTimeout = errors.New("send timeout: pane not idle")

const (
	sendEnterDelay = 200 * time.Millisecond
	// sendSubmitReserve is the part of the send deadline kept for the text, the
	// pause before Enter and Enter. Send does not start typing with less left,
	// so the deadline never strands typed text without its Enter.
	sendSubmitReserve = sendEnterDelay + 300*time.Millisecond
	// sendIdlePoll is how often Send rechecks a pane in copy mode.
	sendIdlePoll = 100 * time.Millisecond
	// sendLockPoll is how often Send retries a send lock another sender holds.
	sendLockPoll = 20 * time.Millisecond
)

var paneIDPattern = regexp.MustCompile(`^%[0-9]+$`)

// Send types text into a pane and presses Enter. SendTimeout bounds the whole
// send: resolving the pane, taking its send lock, waiting for it to leave copy
// mode, the text, the pause before Enter and Enter.
//
// The send lock is a file per pane in lockDir. Callers pass the recorded
// server's directory (state.SendLockDirForServer); legacy still uses the old
// state.SendLockDir path. The lock is held from before the idle check until
// after Enter, so two senders to one pane, in any
// process, never interleave their text and Enter. Text and Enter go to the
// pane ID resolved first, and the pane must still be alive before Enter: keys
// sent to a dead pane vanish without an error.
func (c *Client) Send(ctx context.Context, lockDir, target, text string) SendResult {
	ctx, cancel := context.WithTimeout(ctx, c.SendTimeout)
	defer cancel()
	err := c.send(ctx, lockDir, target, text)
	return SendResult{Submitted: err == nil, Target: target, Err: err}
}

func (c *Client) send(ctx context.Context, lockDir, target, text string) error {
	deadline, _ := ctx.Deadline()
	waitCtx, cancel := context.WithDeadline(ctx, deadline.Add(-sendSubmitReserve))
	defer cancel()

	pane, err := c.livePane(waitCtx, target)
	if err != nil {
		return err
	}
	unlock, err := lockPane(waitCtx, lockDir, pane)
	if err != nil {
		return err
	}
	defer unlock()
	if err := c.waitIdle(waitCtx, pane); err != nil {
		return err
	}
	// Each step above can return at once, even past waitCtx's deadline.
	if err := waitCtx.Err(); err != nil {
		return err
	}

	if _, err := c.runner.Run(ctx, "send-keys", "-t", pane, "-l", "--", text); err != nil {
		return fmt.Errorf("send text: %w", err)
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(sendEnterDelay):
	}
	if _, err := c.livePane(ctx, pane); err != nil {
		return fmt.Errorf("before enter: %w", err)
	}
	if _, err := c.runner.Run(ctx, "send-keys", "-t", pane, "Enter"); err != nil {
		return fmt.Errorf("send enter: %w", err)
	}
	return nil
}

// livePane resolves target to its pane ID and fails when the pane is gone or
// dead. display-message prints empty fields for a pane it cannot find.
func (c *Client) livePane(ctx context.Context, target string) (string, error) {
	out, err := c.runner.Run(ctx, "display-message", "-t", target, "-p", "#{pane_id}\t#{pane_dead}")
	if err != nil {
		return "", fmt.Errorf("find pane %s: %w", target, err)
	}
	pane, dead, _ := strings.Cut(out, "\t")
	if !paneIDPattern.MatchString(pane) {
		return "", fmt.Errorf("pane %s not found", target)
	}
	if dead == "1" {
		return "", fmt.Errorf("pane %s is dead", target)
	}
	return pane, nil
}

// waitIdle waits until the pane leaves copy or choice mode.
func (c *Client) waitIdle(ctx context.Context, pane string) error {
	for {
		idle, err := c.IsPaneIdle(ctx, pane)
		if err != nil {
			return fmt.Errorf("check idle: %w", err)
		}
		if idle {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("%w: %w", ErrSendTimeout, ctx.Err())
		case <-time.After(sendIdlePoll):
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

// lockPane takes a pane's send lock and returns its release. The lock is a file
// in dir, locked with flock and never removed: a sender blocked on a removed
// file and a newcomer on a fresh one would both hold it. flock is tried without
// blocking and retried until ctx ends.
func lockPane(ctx context.Context, dir, pane string) (func(), error) {
	if dir == "" {
		return nil, errors.New("send lock directory is not set")
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create send lock directory: %w", err)
	}
	path := filepath.Join(dir, "pane-"+strings.TrimPrefix(pane, "%")+".lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open send lock: %w", err)
	}
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return func() {
				_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
				_ = f.Close()
			}, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			_ = f.Close()
			return nil, fmt.Errorf("lock %s: %w", path, err)
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, fmt.Errorf("wait for the send lock on pane %s: %w", pane, ctx.Err())
		case <-time.After(sendLockPoll):
		}
	}
}
