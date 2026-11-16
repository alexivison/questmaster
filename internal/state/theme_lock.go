package state

import (
	"context"
	"path/filepath"
)

// WithThemeLock serializes colour reads and tmux writes across CLI and daemon
// processes. Writers commit their metadata first, then read it under this lock
// so an older recolour cannot land after a newer one.
func (s *Store) WithThemeLock(ctx context.Context, fn func() error) error {
	if err := EnsurePrivateStateRoot(s.root); err != nil {
		return err
	}
	return withFileLockContext(ctx, filepath.Join(s.root, "theme.lock"), fn)
}
