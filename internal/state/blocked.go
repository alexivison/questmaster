//go:build linux || darwin

package state

import (
	"context"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

// HasBlockedEpisode includes an unanswered parent dialog temporarily woken by subagents.
func (p PaneState) HasBlockedEpisode() bool {
	return p.State == "blocked" || p.State == "working" && p.SubagentWake != nil &&
		p.SubagentWake.State == "blocked" && len(p.SubagentWake.IDs) > 0
}

// MarkBlockedAlertedAt acknowledges only the episode that was actually delivered.
// A worker that resumed or blocked again while the alert was in flight is untouched.
func MarkBlockedAlertedAt(ctx context.Context, root, id string, since time.Time) error {
	if !IsValidSessionID(id) || root == "" || since.IsZero() {
		return fmt.Errorf("invalid blocked alert acknowledgement for %q", id)
	}
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	lock, err := os.OpenFile(SessionStateLockPath(root, id), os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return err
	}
	defer lock.Close()
	// The daemon retries indefinitely. Unlike short-lived hooks, it must not
	// leave a blocking flock goroutine queued after each cancelled attempt.
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EINTR) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(20 * time.Millisecond):
		}
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	ss, err := loadSessionStateAt(root, id)
	if err != nil || ss == nil {
		return err
	}
	pane := ss.Panes["agent"]
	if !pane.HasBlockedEpisode() || !pane.BlockedSince.Equal(since) || pane.BlockedAlerted {
		return nil
	}
	pane.BlockedAlerted = true
	ss.Panes["agent"] = pane
	return writeSessionStateLocked(root, id, ss)
}
