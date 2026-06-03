package loop

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

// StateWatcher polls one session's state.json for primary-pane done and blocked
// edges. It is intentionally decoupled from the engine and command wiring.
type StateWatcher struct {
	root      string
	sessionID string
	interval  time.Duration
}

// NewStateWatcher returns a poll watcher rooted at stateRoot.
func NewStateWatcher(stateRoot, sessionID string, interval time.Duration) StateWatcher {
	if interval <= 0 {
		interval = 500 * time.Millisecond
	}
	return StateWatcher{root: stateRoot, sessionID: sessionID, interval: interval}
}

// Events starts polling until ctx is canceled. A cold state.json establishes the
// initial high-water mark; only strictly newer done/blocked edges are emitted.
func (w StateWatcher) Events(ctx context.Context) <-chan Event {
	out := make(chan Event)
	go func() {
		defer close(out)
		seenSeq, seenLastEvent := w.currentHighWater()
		ticker := time.NewTicker(w.interval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				pane, ok := w.primaryPane()
				if !ok {
					continue
				}
				if !isNewerPaneEvent(pane, seenSeq, seenLastEvent) {
					continue
				}
				switch pane.State {
				case "done":
					seenSeq, seenLastEvent = pane.Seq, pane.LastEvent
					if !sendEvent(ctx, out, Event{Kind: EventDone}) {
						return
					}
				case "blocked":
					seenSeq, seenLastEvent = pane.Seq, pane.LastEvent
					if !sendEvent(ctx, out, Event{Kind: EventBlocked}) {
						return
					}
				default:
					seenSeq, seenLastEvent = pane.Seq, pane.LastEvent
				}
			}
		}
	}()
	return out
}

func sendEvent(ctx context.Context, ch chan<- Event, ev Event) bool {
	select {
	case <-ctx.Done():
		return false
	case ch <- ev:
		return true
	}
}

func (w StateWatcher) currentHighWater() (int64, time.Time) {
	pane, ok := w.primaryPane()
	if !ok {
		return 0, time.Time{}
	}
	return pane.Seq, pane.LastEvent
}

func (w StateWatcher) primaryPane() (state.PaneState, bool) {
	data, err := os.ReadFile(state.SessionStatePath(w.root, w.sessionID))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return state.PaneState{}, false
		}
		return state.PaneState{}, false
	}
	var ss state.SessionState
	if err := json.Unmarshal(data, &ss); err != nil {
		return state.PaneState{}, false
	}
	if ss.Version != state.SchemaVersion {
		return state.PaneState{}, false
	}
	pane, ok := ss.Panes["primary"]
	return pane, ok
}

func isNewerPaneEvent(pane state.PaneState, seenSeq int64, seenLastEvent time.Time) bool {
	if pane.Seq > seenSeq {
		return true
	}
	if pane.Seq == seenSeq && pane.LastEvent.After(seenLastEvent) {
		return true
	}
	return false
}
