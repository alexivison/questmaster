//go:build linux || darwin

package state

import (
	"context"
	"fmt"
	"time"
)

// MarkBlockedAlertedAt acknowledges only the episode that was actually delivered.
// A worker that resumed or blocked again while the alert was in flight is untouched.
func MarkBlockedAlertedAt(ctx context.Context, root, id string, since time.Time) error {
	if !IsValidSessionID(id) || root == "" || since.IsZero() {
		return fmt.Errorf("invalid blocked alert acknowledgement for %q", id)
	}
	return withStateLockContext(ctx, root, id, func() error {
		ss, err := loadSessionStateAt(root, id)
		if err != nil || ss == nil {
			return err
		}
		pane := ss.Panes["agent"]
		if pane.State != "blocked" || !pane.BlockedSince.Equal(since) || pane.BlockedAlerted {
			return nil
		}
		pane.BlockedAlerted = true
		ss.Panes["agent"] = pane
		return writeSessionStateLocked(root, id, ss)
	})
}
