// Package sessiontheme shares the tracker's session accent with tmux and Pi.
package sessiontheme

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/alexivison/questmaster/internal/tracker"
)

const AccentOption = "@questmaster_session_accent"

const piAccentFile = "pi-accent"

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
			if err != nil {
				errs = append(errs, fmt.Errorf("sync tmux colour for %s: %w", m.SessionID, err))
				continue
			}
			color := colors[m.SessionID]
			accent := palette.Display(color)
			if err := handle.Client().SetSessionOption(ctx, m.SessionID, AccentOption, accent); err != nil {
				errs = append(errs, fmt.Errorf("sync tmux colour for %s: %w", m.SessionID, err))
				continue
			}
			if m.RuntimeDir != "" && slices.ContainsFunc(m.Agents, func(a state.AgentManifest) bool { return a.Name == "pi" }) {
				// An unset or explicitly cleared display colour leaves Pi's
				// native input border in place.
				if color == "" || color == "none" {
					accent = ""
				}
				if err := publishPiAccent(m, accent); err != nil && !errors.Is(err, fs.ErrNotExist) {
					errs = append(errs, fmt.Errorf("publish Pi colour for %s: %w", m.SessionID, err))
				}
			}
		}
		return errors.Join(errs...)
	})
}

// The theme lock serializes writers. Rename publishes a complete value to the
// directory watcher; writing the watched file in place would expose truncation.
func publishPiAccent(m state.Manifest, accent string) error {
	dir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return err
	}
	const temp = "." + piAccentFile + ".tmp"
	if err := state.WriteRuntimeFile(dir, temp, []byte(accent)); err != nil {
		return err
	}
	path := filepath.Join(dir, temp)
	defer os.Remove(path)
	return os.Rename(path, filepath.Join(dir, piAccentFile))
}
