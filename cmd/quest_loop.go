//go:build linux || darwin

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/quests/gate"
	qloop "github.com/alexivison/questmaster/internal/quests/loop"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	defaultLoopMaxIters       = 6
	defaultLoopMaxTime        = 20 * time.Minute
	defaultLoopStuckAfter     = 3
	defaultLoopBlockedTimeout = 10 * time.Minute
	defaultLoopPollInterval   = 100 * time.Millisecond
)

type questLoopTarget struct {
	QuestID  string
	Quest    *quest.Quest
	Autos    []quest.Gate
	Worktree string
}

func newQuestLoopCmd(o *questOpts) *cobra.Command {
	var maxIters int
	var maxTime time.Duration
	var stuckAfter int
	var force bool

	cmd := &cobra.Command{
		Use:   "loop <session>",
		Short: "Run an armed quest auto-gate loop for one session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt)
			defer stop()

			return runQuestLoop(ctx, cmd.OutOrStdout(), o, args[0], questLoopRunOptions{
				MaxIters:       maxIters,
				MaxTime:        maxTime,
				StuckAfter:     stuckAfter,
				BlockedTimeout: defaultLoopBlockedTimeout,
				Force:          force,
			})
		},
	}
	cmd.Flags().IntVar(&maxIters, "max-iters", defaultLoopMaxIters, "maximum check iterations before stopping")
	cmd.Flags().DurationVar(&maxTime, "max-time", defaultLoopMaxTime, "maximum wall-clock time before stopping")
	cmd.Flags().IntVar(&stuckAfter, "stuck-after", defaultLoopStuckAfter, "stop after this many identical failure signatures")
	cmd.Flags().BoolVar(&force, "force", false, "replace a stale quest-loop marker")
	return cmd
}

type questLoopRunOptions struct {
	MaxIters       int
	MaxTime        time.Duration
	StuckAfter     int
	BlockedTimeout time.Duration
	Force          bool
}

func runQuestLoop(ctx context.Context, w io.Writer, o *questOpts, sessionID string, opts questLoopRunOptions) error {
	if !state.IsValidSessionID(sessionID) {
		return fmt.Errorf("invalid session id: %q", sessionID)
	}
	store := o.store
	if store == nil {
		store = state.OpenStore(state.StateRoot())
	}
	client := o.client
	if client == nil {
		client = tmux.NewExecClient()
	}

	target, err := resolveQuestLoopTarget(sessionID, store)
	if err != nil {
		return err
	}

	if err := state.ArmQuestLoop(sessionID, o.now(), opts.Force); err != nil {
		if errors.Is(err, state.ErrQuestLoopArmed) {
			return fmt.Errorf("quest loop is already armed for %s; use --force to replace a stale marker", sessionID)
		}
		return err
	}
	defer state.ClearQuestLoop(sessionID) //nolint:errcheck

	printLoopHeader(w, sessionID, target, opts)

	msgSvc := message.NewService(store, client)
	watcher := qloop.NewStateWatcher(state.StateRoot(), sessionID, defaultLoopPollInterval)
	engine := qloop.Engine{
		Check: func(ctx context.Context) ([]gate.Result, error) {
			return runQuestAutoChecks(target.QuestID, target.Autos, target.Worktree)
		},
		Inject: func(ctx context.Context, msg string) error {
			return msgSvc.Relay(ctx, sessionID, msg)
		},
		Events: watcher.Events(ctx),
		Clock:  loopClock{},
		Config: qloop.Config{
			MaxIters:       opts.MaxIters,
			MaxWall:        opts.MaxTime,
			StuckAfter:     opts.StuckAfter,
			BlockedTimeout: opts.BlockedTimeout,
		},
		OnBlocked: func() {
			fmt.Fprintln(w, "blocked: agent is waiting for human input; loop paused")
		},
		OnIteration: func(iter qloop.Iteration) {
			_ = state.UpdateQuestLoop(sessionID, iter.Number, string(iter.Verdict))
			printLoopIteration(w, iter)
		},
	}

	outcome := engine.Run(ctx)
	printLoopOutcome(w, outcome)
	if outcome.Kind == qloop.OutcomeError {
		return outcome.Err
	}
	return nil
}

func resolveQuestLoopTarget(sessionID string, store *state.Store) (questLoopTarget, error) {
	questID, err := state.QuestIDForSession(sessionID)
	if err != nil {
		return questLoopTarget{}, err
	}
	if questID == "" {
		return questLoopTarget{}, fmt.Errorf("session %s is not attached to an active quest", sessionID)
	}

	q, err := quest.DefaultStore().Load(questID)
	if err != nil {
		return questLoopTarget{}, err
	}
	if q.Status != quest.StatusActive {
		return questLoopTarget{}, fmt.Errorf("quest %s is %s, not active", questID, q.Status)
	}
	autos := questAutoGates(q)
	if len(autos) == 0 {
		return questLoopTarget{}, fmt.Errorf("quest %s has no auto gates to loop", questID)
	}

	m, err := store.Read(sessionID)
	if err != nil {
		return questLoopTarget{}, fmt.Errorf("read session manifest %s: %w", sessionID, err)
	}
	if strings.TrimSpace(m.Cwd) == "" {
		return questLoopTarget{}, fmt.Errorf("session %s has no worktree; attach the quest to a session with a cwd", sessionID)
	}

	return questLoopTarget{
		QuestID:  questID,
		Quest:    q,
		Autos:    autos,
		Worktree: m.Cwd,
	}, nil
}

func printLoopHeader(w io.Writer, sessionID string, target questLoopTarget, opts questLoopRunOptions) {
	fmt.Fprintf(w, "qm quest loop armed\n")
	fmt.Fprintf(w, "  session:  %s\n", sessionID)
	fmt.Fprintf(w, "  quest:    %s — %s\n", target.QuestID, target.Quest.Title)
	fmt.Fprintf(w, "  worktree: %s\n", target.Worktree)
	fmt.Fprintf(w, "  limits:   max-iters=%d max-time=%s stuck-after=%d\n", opts.MaxIters, opts.MaxTime, opts.StuckAfter)
	fmt.Fprintln(w, "waiting for done edges...")
}

func printLoopIteration(w io.Writer, iter qloop.Iteration) {
	fmt.Fprintf(w, "iteration %d: %s\n", iter.Number, iter.Verdict)
	for _, r := range iter.Results {
		label := string(r.Status)
		if r.Misconfigured() {
			label = "misconfigured"
		}
		fmt.Fprintf(w, "  %-13s %s\n", label, r.Gate)
	}
}

func printLoopOutcome(w io.Writer, outcome qloop.Outcome) {
	switch outcome.Kind {
	case qloop.OutcomeGreen:
		fmt.Fprintln(w, "terminal: all autos green — yours to verify + stamp.")
	case qloop.OutcomeMisconfigured:
		for _, line := range qloop.MisconfiguredLines(outcome.LastResults) {
			fmt.Fprintln(w, line)
		}
		fmt.Fprintln(w, "terminal: misconfigured check; loop paused for human fix.")
	case qloop.OutcomeStopped:
		fmt.Fprintf(w, "terminal: stopped (%s)\n", outcome.Reason)
		printLoopLastVerdict(w, outcome.LastResults)
	case qloop.OutcomeError:
		fmt.Fprintf(w, "terminal: error (%v)\n", outcome.Err)
		printLoopLastVerdict(w, outcome.LastResults)
	}
}

func printLoopLastVerdict(w io.Writer, results []gate.Result) {
	if len(results) == 0 {
		fmt.Fprintln(w, "last verdict: none")
		return
	}
	fmt.Fprintln(w, "last verdict:")
	for _, r := range results {
		label := string(r.Status)
		if r.Misconfigured() {
			label = "misconfigured"
		}
		fmt.Fprintf(w, "  %-13s %s\n", label, r.Gate)
	}
}

type loopClock struct{}

func (loopClock) Now() time.Time { return time.Now().UTC() }

func (loopClock) After(d time.Duration) <-chan time.Time {
	return time.After(d)
}
