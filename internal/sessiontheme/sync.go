// Package sessiontheme keeps tmux's session accent in step with tracker colours.
package sessiontheme

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/alexivison/questmaster/internal/tracker"
)

const AccentOption = "@questmaster_session_accent"

// Sync refreshes live sessions after a colour change or config reload. A
// nonempty sessionID targets a newly launched session directly. Otherwise one
// inventory per server identifies the live sessions; stopped manifests never
// receive options and cannot fall through to tmux's current session.
func Sync(ctx context.Context, store *state.Store, router *tmuxroute.Router, sessionID string) error {
	if router == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	return store.WithThemeLock(ctx, func() error {
		manifests, err := store.DiscoverSessions()
		if err != nil {
			return err
		}
		if len(manifests) == 0 {
			return nil
		}
		colors := tracker.ResolveDisplayColors(store, manifests)
		live := map[string]bool{}
		if sessionID == "" {
			inventory := router.Inventory(ctx)
			for _, server := range inventory.Servers {
				if server.Outcome == tmuxroute.Unavailable {
					return fmt.Errorf("sync tmux colours: server %s unavailable: %s", server.Label, server.Error)
				}
			}
			for _, row := range inventory.Rows {
				live[row.Label+"\x00"+row.ID] = true
			}
		}
		var errs []error
		for _, m := range manifests {
			if m.NeedsTmuxBackfill() || (sessionID != "" && m.SessionID != sessionID) {
				continue
			}
			if sessionID == "" && !live[string(m.TmuxServer)+"\x00"+m.SessionID] {
				continue
			}
			handle, err := router.Route(m)
			if err == nil {
				err = handle.Client().SetSessionOption(ctx, m.SessionID, AccentOption, palette.Display(colors[m.SessionID]))
			}
			if err != nil {
				errs = append(errs, fmt.Errorf("sync tmux colour for %s: %w", m.SessionID, err))
			}
		}
		return errors.Join(errs...)
	})
}
