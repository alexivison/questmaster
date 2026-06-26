//go:build linux || darwin

package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"time"

	"github.com/spf13/cobra"

	"github.com/alexivison/questmaster/internal/quests/gate"
	qloop "github.com/alexivison/questmaster/internal/quests/loop"
	"github.com/alexivison/questmaster/internal/quests/looprun"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

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

			return runQuestLoop(ctx, cmd.OutOrStdout(), o, args[0], looprun.Options{
				MaxIters:       maxIters,
				MaxTime:        maxTime,
				StuckAfter:     stuckAfter,
				BlockedTimeout: looprun.DefaultBlockedTimeout,
				PollInterval:   looprun.DefaultPollInterval,
			}, force)
		},
	}
	cmd.Flags().IntVar(&maxIters, "max-iters", looprun.DefaultMaxIters, "maximum check iterations before stopping")
	cmd.Flags().DurationVar(&maxTime, "max-time", looprun.DefaultMaxTime, "maximum wall-clock time before stopping")
	cmd.Flags().IntVar(&stuckAfter, "stuck-after", looprun.DefaultStuckAfter, "stop after this many identical failure signatures")
	cmd.Flags().BoolVar(&force, "force", false, "replace a stale quest-loop marker")
	return cmd
}

func runQuestLoop(ctx context.Context, w io.Writer, o *questOpts, sessionID string, opts looprun.Options, force bool) error {
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

	target, err := looprun.ResolveTarget(sessionID, store)
	if err != nil {
		return err
	}

	// The foreground command owns its marker; the serve supervisor refuses to
	// run a loop for a foreground-owned marker, so the two never double-run.
	if err := state.ArmQuestLoop(sessionID, o.now(), force, state.QuestLoopOwnerForeground); err != nil {
		if errors.Is(err, state.ErrQuestLoopArmed) {
			return fmt.Errorf("quest loop is already armed for %s; use --force to replace a stale marker", sessionID)
		}
		return err
	}
	defer state.ClearQuestLoop(sessionID) //nolint:errcheck

	printLoopHeader(w, sessionID, target, opts)

	outcome := looprun.Run(ctx, store, client, sessionID, target, opts, looprun.Callbacks{
		OnBlocked: func() {
			fmt.Fprintln(w, "blocked: agent is waiting for human input; loop paused")
		},
		OnIteration: func(iter qloop.Iteration) {
			printLoopIteration(w, iter)
		},
	})
	printLoopOutcome(w, outcome)
	if outcome.Kind == qloop.OutcomeError {
		return outcome.Err
	}
	return nil
}

func printLoopHeader(w io.Writer, sessionID string, target looprun.Target, opts looprun.Options) {
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
