//go:build linux || darwin

// Package looprun is the shared assembly layer for the quest auto-gate loop. It
// wires the pure engine in internal/quests/loop to its real collaborators (gate
// checks + sidecar, tmux message relay, the session-state watcher) so both the
// foreground `qm quest loop` command and the serve-owned supervisor run the
// loop through one path. The engine itself stays side-effect free; this package
// owns the side effects.
package looprun

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/quests/gate"
	qloop "github.com/alexivison/questmaster/internal/quests/loop"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Default loop budgets, shared by the CLI command and the serve supervisor so
// there is one source of truth for the loop's stop conditions.
const (
	DefaultMaxIters       = 6
	DefaultMaxTime        = 20 * time.Minute
	DefaultStuckAfter     = 3
	DefaultBlockedTimeout = 10 * time.Minute
	DefaultPollInterval   = 100 * time.Millisecond
)

// Per-gate deadlines bound a single check so one wedged process can't hang the
// loop. cmd: checks may be real builds/tests (generous); github: checks are
// network round-trips that should be quick.
const (
	cmdGateTimeout    = 10 * time.Minute
	githubGateTimeout = 45 * time.Second
)

// Options holds the loop stop conditions for one run.
type Options struct {
	MaxIters       int
	MaxTime        time.Duration
	StuckAfter     int
	BlockedTimeout time.Duration
	PollInterval   time.Duration
}

// DefaultOptions returns the shared default budgets.
func DefaultOptions() Options {
	return Options{
		MaxIters:       DefaultMaxIters,
		MaxTime:        DefaultMaxTime,
		StuckAfter:     DefaultStuckAfter,
		BlockedTimeout: DefaultBlockedTimeout,
		PollInterval:   DefaultPollInterval,
	}
}

// Target is a resolved, validated quest-loop run target.
type Target struct {
	QuestID  string
	Quest    *quest.Quest
	Autos    []quest.Gate
	Worktree string
}

// SidecarDir is the auto-gate result sidecar root: a sibling of the quest store
// under qm's dotfiles, holding observed auto-gate results. Never a repo.
func SidecarDir() string {
	return filepath.Join(quest.Home(), "runtime")
}

// AutoGates returns a quest's auto gates — the only gates the loop runs. A quest
// with only toggle gates has nothing to loop.
func AutoGates(q *quest.Quest) []quest.Gate {
	var autos []quest.Gate
	for _, g := range q.Gates {
		if g.Type == quest.GateAuto {
			autos = append(autos, g)
		}
	}
	return autos
}

// ResolveTarget validates that a session is attached to an active quest with at
// least one auto gate and a worktree to run checks in.
func ResolveTarget(sessionID string, store *state.Store) (Target, error) {
	questID, err := state.QuestIDForSession(sessionID)
	if err != nil {
		return Target{}, err
	}
	if questID == "" {
		return Target{}, fmt.Errorf("session %s is not attached to an active quest", sessionID)
	}

	q, err := quest.DefaultStore().Load(questID)
	if err != nil {
		return Target{}, err
	}
	if q.Status != quest.StatusActive {
		return Target{}, fmt.Errorf("quest %s is %s, not active", questID, q.Status)
	}
	autos := AutoGates(q)
	if len(autos) == 0 {
		return Target{}, fmt.Errorf("quest %s has no auto gates to loop", questID)
	}

	m, err := store.Read(sessionID)
	if err != nil {
		return Target{}, fmt.Errorf("read session manifest %s: %w", sessionID, err)
	}
	if strings.TrimSpace(m.Cwd) == "" {
		return Target{}, fmt.Errorf("session %s has no worktree; attach the quest to a session with a cwd", sessionID)
	}

	return Target{QuestID: questID, Quest: q, Autos: autos, Worktree: m.Cwd}, nil
}

// RunAutoChecks runs each auto gate under its own deadline and records the
// results to the sidecar. It never mutates the quest JSON.
func RunAutoChecks(ctx context.Context, questID string, autos []quest.Gate, worktree string) ([]gate.Result, error) {
	results := make([]gate.Result, 0, len(autos))
	for _, g := range autos {
		results = append(results, runGateWithTimeout(ctx, g, worktree))
	}
	if err := gate.NewSidecar(SidecarDir()).Save(questID, results); err != nil {
		return results, err
	}
	return results, nil
}

// runGateWithTimeout runs one gate under its own deadline derived from ctx, so a
// stalled gate fails as a (misconfigured) error rather than blocking the loop,
// while a parent cancellation (Ctrl-C, loop stop) still interrupts it promptly.
func runGateWithTimeout(ctx context.Context, g quest.Gate, worktree string) gate.Result {
	timeout := cmdGateTimeout
	if strings.HasPrefix(strings.TrimSpace(g.Check), "github:") {
		timeout = githubGateTimeout
	}
	cctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return gate.RunCheck(cctx, g.Name, g.Check, worktree)
}

// Callbacks surface loop progress for console/UI reporting. All are optional;
// the marker progress (iterations/verdict/phase) is written regardless.
type Callbacks struct {
	OnChecking  func()
	OnBlocked   func()
	OnIteration func(qloop.Iteration)
}

// Clock is the production clock used by the loop engine.
type Clock struct{}

// Now returns the current UTC time.
func (Clock) Now() time.Time { return time.Now().UTC() }

// After is time.After.
func (Clock) After(d time.Duration) <-chan time.Time { return time.After(d) }

// Run assembles and runs the loop engine for a resolved target. It updates the
// advisory marker's progress (iterations/verdict/phase) as it goes, but does
// NOT arm or clear the marker — the marker lifecycle (and its owner) belongs to
// the caller, because the foreground command and the supervisor own it
// differently.
func Run(ctx context.Context, store *state.Store, client *tmux.Client, sessionID string, target Target, opts Options, cb Callbacks) qloop.Outcome {
	msgSvc := message.NewService(store, client)
	poll := opts.PollInterval
	if poll <= 0 {
		poll = DefaultPollInterval
	}
	watcher := qloop.NewStateWatcher(store.Root(), sessionID, poll)

	engine := qloop.Engine{
		Check: func(ctx context.Context) ([]gate.Result, error) {
			return RunAutoChecks(ctx, target.QuestID, target.Autos, target.Worktree)
		},
		Inject: func(ctx context.Context, msg string) error {
			return msgSvc.Relay(ctx, sessionID, msg)
		},
		Events: watcher.Events(ctx),
		Clock:  Clock{},
		Config: qloop.Config{
			MaxIters:       opts.MaxIters,
			MaxWall:        opts.MaxTime,
			StuckAfter:     opts.StuckAfter,
			BlockedTimeout: opts.BlockedTimeout,
		},
		OnBlocked: func() {
			_ = state.SetQuestLoopPhase(sessionID, state.QuestLoopPhasePaused)
			if cb.OnBlocked != nil {
				cb.OnBlocked()
			}
		},
		OnChecking: func() {
			_ = state.SetQuestLoopPhase(sessionID, state.QuestLoopPhaseChecking)
			if cb.OnChecking != nil {
				cb.OnChecking()
			}
		},
		OnIteration: func(iter qloop.Iteration) {
			_ = state.UpdateQuestLoop(sessionID, iter.Number, string(iter.Verdict), state.QuestLoopPhaseWaiting)
			if cb.OnIteration != nil {
				cb.OnIteration(iter)
			}
		},
	}

	return engine.Run(ctx)
}
