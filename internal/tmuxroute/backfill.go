package tmuxroute

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const maxBackfillErrors = 20

// BackfillResult counts every manifest considered, including unreadable ones.
type BackfillResult struct {
	Updated           int      `json:"updated"`
	SkippedLive       int      `json:"skipped_live"`
	SkippedAlreadySet int      `json:"skipped_already_set"`
	Failed            int      `json:"failed"`
	Errors            []string `json:"errors,omitempty"`
}

// Backfill upgrades only stopped manifests. Each candidate is read directly
// under its lifecycle lock: absent ownership must never pass through Route.
func (r *Router) Backfill(ctx context.Context) (BackfillResult, error) {
	var result BackfillResult
	r.Invalidate()
	snapshot, err := r.AuditInventory(ctx)
	if err != nil {
		return result, fmt.Errorf("snapshot tmux sessions: %w", err)
	}
	liveAtSnapshot := make(map[string]bool, len(snapshot.Rows))
	for _, row := range snapshot.Rows {
		liveAtSnapshot[row.ID] = true
	}
	handles, err := r.KnownHandles()
	if err != nil {
		return result, err
	}
	dir, err := os.Open(r.store.Root())
	if err != nil {
		return result, err
	}
	defer dir.Close()
	for {
		entries, readErr := dir.ReadDir(128)
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
				continue
			}
			id := strings.TrimSuffix(entry.Name(), ".json")
			if !state.IsValidSessionID(id) {
				continue
			}
			lockCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			if r.beforeLifecycleLock != nil {
				r.beforeLifecycleLock()
			}
			err := r.store.WithLifecycleLockContext(lockCtx, id, func() error {
				m, err := r.store.Read(id)
				if err != nil {
					return err
				}
				if m.TmuxServer != "" && m.TmuxServer != "default" {
					if err := tmux.ValidateNamedLabel(string(m.TmuxServer)); err != nil {
						return err
					}
					result.SkippedAlreadySet++
					return nil
				}
				if liveAtSnapshot[id] {
					result.SkippedLive++
					return nil
				}
				for _, handle := range handles {
					live, err := handle.Client().HasSession(lockCtx, id)
					if err != nil {
						return err
					}
					if live {
						result.SkippedLive++
						return nil
					}
				}
				updated, err := r.store.BackfillTmuxServer(id)
				if err != nil {
					return err
				}
				if updated {
					result.Updated++
				} else {
					result.SkippedAlreadySet++
				}
				return nil
			})
			cancel()
			if err != nil {
				result.Failed++
				// Keep diagnostics bounded even for a large stopped-session archive.
				if len(result.Errors) < maxBackfillErrors {
					result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", id, err))
				}
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return result, readErr
		}
	}
	r.Invalidate()
	return result, nil
}

func (r *Router) probeDefault(ctx context.Context) ([]string, bool, error) {
	if r.defaultProbe == nil {
		return nil, false, fmt.Errorf("default server audit probe is unavailable")
	}
	callCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return r.defaultProbe(callCtx)
}
