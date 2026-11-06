package state

import (
	"context"
	"fmt"
)

// PaneTitleWriter sets a pane's managed title. *tmux.Client implements it.
type PaneTitleWriter interface {
	SetManagedPaneTitle(ctx context.Context, target, title string) error
}

// ManifestReader reads a session manifest. *Store implements it.
type ManifestReader interface {
	Read(sessionID string) (Manifest, error)
}

// maxPaneTitleWrites bounds WriteCommittedPaneTitle: each write after the
// first follows a title that committed while the previous one was in flight.
const maxPaneTitleWrites = 3

// WriteCommittedPaneTitle puts title, which the caller has already committed
// to the session's manifest, on pane.
//
// It runs after the manifest lock is released, because a tmux call under that
// lock would hold every other manifest writer behind tmux. So a rename can
// commit while this write is in flight, and its own pane write can land
// first. After each write the manifest is read again, and if its title has
// moved on, the newer title is written. Each writer checks the manifest after
// its last write, so the pane ends with the newest committed title. A
// manifest with no title or no agent left owns no pane title, and the check
// stops there.
func WriteCommittedPaneTitle(ctx context.Context, manifests ManifestReader, panes PaneTitleWriter, sessionID, pane, title string) error {
	for range maxPaneTitleWrites {
		if err := panes.SetManagedPaneTitle(ctx, pane, title); err != nil {
			return err
		}
		m, err := manifests.Read(sessionID)
		if err != nil {
			return fmt.Errorf("re-read title after pane write: %w", err)
		}
		if m.Title == title || m.Title == "" || len(m.Agents) == 0 {
			return nil
		}
		title = m.Title
	}
	return fmt.Errorf("title of %s changed during %d pane writes", sessionID, maxPaneTitleWrites)
}
