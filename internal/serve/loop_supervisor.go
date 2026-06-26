//go:build linux || darwin

package serve

import (
	"context"
	"sync"
	"time"

	qloop "github.com/alexivison/questmaster/internal/quests/loop"
	"github.com/alexivison/questmaster/internal/quests/looprun"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const defaultLoopReconcileInterval = 2 * time.Second

// loopSupervisor auto-arms and runs the quest auto-gate loop for quest-attached
// sessions while `qm serve` is up. It is the wiring that makes the loop reach
// users who never run `qm quest loop` by hand: when a live session is attached
// to an active quest with at least one auto gate, the supervisor arms a
// supervisor-owned marker and runs the loop engine in-process, then cancels it
// when the session ends, detaches, the quest leaves active, or the session is
// suppressed (`--no-loop`). It never runs a loop for a foreground-owned marker.
//
// A finished loop is left with a terminal-phase marker rather than a cleared
// one, so the supervisor does not immediately restart a loop that already
// settled (green / stuck / budget / misconfigured). The marker resets when the
// session ends or the loop is explicitly re-armed.
type loopSupervisor struct {
	store  *state.Store
	client *tmux.Client
	now    func() time.Time

	mu      sync.Mutex
	running map[string]context.CancelFunc
}

func newLoopSupervisor(store *state.Store, client *tmux.Client, now func() time.Time) *loopSupervisor {
	if now == nil {
		now = time.Now
	}
	return &loopSupervisor{
		store:   store,
		client:  client,
		now:     now,
		running: map[string]context.CancelFunc{},
	}
}

// Run reconciles on a ticker until ctx is canceled, then cancels every running
// loop.
func (sv *loopSupervisor) Run(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		interval = defaultLoopReconcileInterval
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	sv.reconcile(ctx)
	for {
		select {
		case <-ctx.Done():
			sv.cancelAll()
			return
		case <-ticker.C:
			sv.reconcile(ctx)
		}
	}
}

func (sv *loopSupervisor) cancelAll() {
	sv.mu.Lock()
	defer sv.mu.Unlock()
	for sid, cancel := range sv.running {
		cancel()
		delete(sv.running, sid)
	}
}

func (sv *loopSupervisor) reconcile(ctx context.Context) {
	if sv.client == nil || sv.store == nil {
		return
	}
	sessions, err := sv.client.ListSessions(ctx)
	if err != nil {
		return
	}
	live := make(map[string]struct{}, len(sessions))
	for _, sid := range sessions {
		live[sid] = struct{}{}
	}

	// Stop loops whose session is no longer live and drop their marker.
	sv.mu.Lock()
	for sid, cancel := range sv.running {
		if _, ok := live[sid]; !ok {
			cancel()
			delete(sv.running, sid)
			_ = state.ClearQuestLoop(sid)
		}
	}
	sv.mu.Unlock()

	for sid := range live {
		sv.reconcileSession(ctx, sid)
	}
}

func (sv *loopSupervisor) reconcileSession(ctx context.Context, sessionID string) {
	if !state.IsValidSessionID(sessionID) {
		return
	}
	ss, err := state.LoadSessionStateAt(sv.store.Root(), sessionID)
	if err != nil || ss == nil {
		sv.stop(sessionID, false)
		return
	}

	// A foreground `qm quest loop` owns its marker; never double-run.
	if ss.QuestLoop != nil && ss.QuestLoop.Owner == state.QuestLoopOwnerForeground {
		return
	}
	// Opted out of the auto-armed loop.
	if ss.QuestLoopSuppressed {
		sv.stop(sessionID, false)
		return
	}
	// A settled (terminal) marker means: do not restart until it resets.
	if ss.QuestLoop != nil && state.IsQuestLoopTerminalPhase(ss.QuestLoop.Phase) {
		sv.stop(sessionID, false)
		return
	}

	target, err := looprun.ResolveTarget(sessionID, sv.store)
	if err != nil {
		// Not eligible: no active quest with an auto gate and a worktree. Clear
		// a stale supervisor marker we may have armed earlier (e.g. the quest
		// was turned in or detached) and stop any running loop.
		clear := ss.QuestLoop != nil && ss.QuestLoop.Owner == state.QuestLoopOwnerSupervisor
		sv.stop(sessionID, clear)
		return
	}

	sv.mu.Lock()
	if _, running := sv.running[sessionID]; running {
		sv.mu.Unlock()
		return
	}
	// Arm a fresh supervisor marker only when none exists; an existing
	// non-terminal supervisor marker (e.g. after a serve restart) is run as-is.
	if ss.QuestLoop == nil {
		if err := state.ArmQuestLoop(sessionID, sv.now(), false, state.QuestLoopOwnerSupervisor); err != nil {
			sv.mu.Unlock()
			return
		}
	}
	loopCtx, cancel := context.WithCancel(ctx)
	sv.running[sessionID] = cancel
	sv.mu.Unlock()

	go sv.runLoop(loopCtx, sessionID, target)
}

func (sv *loopSupervisor) runLoop(ctx context.Context, sessionID string, target looprun.Target) {
	outcome := looprun.Run(ctx, sv.store, sv.client, sessionID, target, looprun.DefaultOptions(), looprun.Callbacks{})

	sv.mu.Lock()
	delete(sv.running, sessionID)
	sv.mu.Unlock()

	// If the loop was canceled (session gone, suppressed, serve shutdown), the
	// canceling path owns the marker — leave it alone. Otherwise record the
	// terminal phase so reconcile does not immediately restart a settled loop.
	if ctx.Err() != nil {
		return
	}
	_ = state.SetQuestLoopPhase(sessionID, terminalLoopPhase(outcome))
}

func (sv *loopSupervisor) stop(sessionID string, clearMarker bool) {
	sv.mu.Lock()
	if cancel, ok := sv.running[sessionID]; ok {
		cancel()
		delete(sv.running, sessionID)
	}
	sv.mu.Unlock()
	if clearMarker {
		_ = state.ClearQuestLoop(sessionID)
	}
}

func terminalLoopPhase(o qloop.Outcome) string {
	switch o.Kind {
	case qloop.OutcomeGreen:
		return state.QuestLoopPhaseGreen
	case qloop.OutcomeMisconfigured:
		return state.QuestLoopPhaseMisconfigured
	case qloop.OutcomeError:
		return state.QuestLoopPhaseError
	default:
		return state.QuestLoopPhaseStopped
	}
}
