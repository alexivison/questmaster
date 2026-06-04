package loop

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
)

const (
	messageHeadLines = 12
	messageTailLines = 12
	messageMaxChars  = 4000
)

// EventKind is an observed agent-state transition relevant to the loop.
type EventKind string

const (
	EventDone    EventKind = "done"
	EventBlocked EventKind = "blocked"
)

// Event is a turn-end or pause signal supplied by a watcher.
type Event struct {
	Kind EventKind
}

// CheckRunner runs one auto-gate iteration.
type CheckRunner func(context.Context) ([]gate.Result, error)

// Injector relays one real auto-gate failure message back to the agent.
type Injector func(context.Context, string) error

// Clock is injected so the engine owns no global clock.
type Clock interface {
	Now() time.Time
	After(time.Duration) <-chan time.Time
}

// Config holds the loop stop conditions. Zero values disable that ceiling.
type Config struct {
	MaxIters       int
	MaxWall        time.Duration
	StuckAfter     int
	BlockedTimeout time.Duration
}

// OutcomeKind is the terminal result of a loop run.
type OutcomeKind string

const (
	OutcomeGreen         OutcomeKind = "green"
	OutcomeMisconfigured OutcomeKind = "misconfigured"
	OutcomeStopped       OutcomeKind = "stopped"
	OutcomeError         OutcomeKind = "error"
)

// StopReason explains an OutcomeStopped result.
type StopReason string

const (
	StopBudget         StopReason = "budget"
	StopStuck          StopReason = "stuck"
	StopBlockedTimeout StopReason = "blocked_timeout"
	StopCanceled       StopReason = "canceled"
	StopEventSource    StopReason = "event_source_closed"
)

// Iteration is emitted after each check run for console/UI reporting.
type Iteration struct {
	Number  int
	Results []gate.Result
	Verdict Verdict
}

// Engine is the pure quest loop core. All side effects are supplied by
// collaborators; it does not touch tmux, the filesystem, quest status, or gates.
type Engine struct {
	Check  CheckRunner
	Inject Injector
	Events <-chan Event
	Clock  Clock
	Config Config

	OnIteration func(Iteration)
	OnBlocked   func()
}

// Outcome describes why the engine stopped.
type Outcome struct {
	Kind        OutcomeKind
	Reason      StopReason
	Iterations  int
	LastResults []gate.Result
	Err         error
}

// Verdict is the per-check classification from gate results.
type Verdict string

const (
	VerdictGreen         Verdict = "green"
	VerdictFail          Verdict = "fail"
	VerdictMisconfigured Verdict = "misconfigured"
)

// Run watches the injected event source, runs checks on done edges, injects
// real failures, and stops on green, misconfiguration, budget, stuck, blocked
// timeout, or context cancellation.
func (e Engine) Run(ctx context.Context) Outcome {
	if e.Check == nil {
		return Outcome{Kind: OutcomeError, Err: errors.New("loop check runner is required")}
	}
	if e.Inject == nil {
		return Outcome{Kind: OutcomeError, Err: errors.New("loop injector is required")}
	}
	if e.Events == nil {
		return Outcome{Kind: OutcomeError, Err: errors.New("loop event source is required")}
	}
	if e.Clock == nil {
		return Outcome{Kind: OutcomeError, Err: errors.New("loop clock is required")}
	}

	var wall <-chan time.Time
	if e.Config.MaxWall > 0 {
		wall = e.Clock.After(e.Config.MaxWall)
	}
	var blockedTimeout <-chan time.Time

	var iterations int
	var last []gate.Result
	var lastSignature string
	var repeatSignature int

	for {
		select {
		case <-ctx.Done():
			return Outcome{Kind: OutcomeStopped, Reason: StopCanceled, Iterations: iterations, LastResults: last, Err: ctx.Err()}
		case <-wall:
			return Outcome{Kind: OutcomeStopped, Reason: StopBudget, Iterations: iterations, LastResults: last}
		case <-blockedTimeout:
			return Outcome{Kind: OutcomeStopped, Reason: StopBlockedTimeout, Iterations: iterations, LastResults: last}
		case ev, ok := <-e.Events:
			if !ok {
				return Outcome{Kind: OutcomeStopped, Reason: StopEventSource, Iterations: iterations, LastResults: last}
			}
			switch ev.Kind {
			case EventBlocked:
				if e.OnBlocked != nil {
					e.OnBlocked()
				}
				if e.Config.BlockedTimeout > 0 {
					blockedTimeout = e.Clock.After(e.Config.BlockedTimeout)
				}
			case EventDone:
				blockedTimeout = nil
				results, err := e.Check(ctx)
				if err != nil {
					return Outcome{Kind: OutcomeError, Iterations: iterations, LastResults: last, Err: err}
				}
				iterations++
				last = cloneResults(results)
				verdict := Classify(results)
				if e.OnIteration != nil {
					e.OnIteration(Iteration{Number: iterations, Results: cloneResults(results), Verdict: verdict})
				}

				switch verdict {
				case VerdictGreen:
					return Outcome{Kind: OutcomeGreen, Iterations: iterations, LastResults: last}
				case VerdictMisconfigured:
					return Outcome{Kind: OutcomeMisconfigured, Iterations: iterations, LastResults: last}
				case VerdictFail:
					signature := failureSignature(results)
					if signature == lastSignature {
						repeatSignature++
					} else {
						lastSignature = signature
						repeatSignature = 1
					}
					if e.Config.StuckAfter > 0 && repeatSignature >= e.Config.StuckAfter {
						return Outcome{Kind: OutcomeStopped, Reason: StopStuck, Iterations: iterations, LastResults: last}
					}
					if e.Config.MaxIters > 0 && iterations >= e.Config.MaxIters {
						return Outcome{Kind: OutcomeStopped, Reason: StopBudget, Iterations: iterations, LastResults: last}
					}
					if err := e.Inject(ctx, FailureMessage(results)); err != nil {
						return Outcome{Kind: OutcomeError, Iterations: iterations, LastResults: last, Err: err}
					}
				}
			}
		}
	}
}

// Classify collapses one check result slice into the loop's iteration verdict.
func Classify(results []gate.Result) Verdict {
	hasFail := false
	for _, r := range results {
		switch r.Status {
		case gate.StatusError:
			return VerdictMisconfigured
		case gate.StatusFail:
			hasFail = true
		case gate.StatusPass:
		default:
			return VerdictMisconfigured
		}
	}
	if hasFail {
		return VerdictFail
	}
	return VerdictGreen
}

// FailureMessage renders the bounded prompt injected after real auto-gate
// failures. It asks the agent to fix the work, never to mutate quest state.
func FailureMessage(results []gate.Result) string {
	failures := failingResults(results)
	names := make([]string, 0, len(failures))
	for _, r := range failures {
		names = append(names, r.Gate)
	}

	var b strings.Builder
	fmt.Fprintln(&b, "qm ran the quest auto gates and found failing work.")
	fmt.Fprintf(&b, "Failing gates: %s\n\n", strings.Join(names, ", "))
	fmt.Fprintln(&b, "Fix the work so the check passes. qm will re-run the auto gates after your next turn.")
	for _, r := range failures {
		fmt.Fprintf(&b, "\n%s output:\n%s\n", r.Gate, boundedOutput(r.Output))
	}
	return strings.TrimRight(b.String(), "\n")
}

// MisconfiguredLines renders console-only diagnostics for broken checks.
func MisconfiguredLines(results []gate.Result) []string {
	var lines []string
	for _, r := range results {
		if r.Status != gate.StatusError {
			continue
		}
		reason := oneLineReason(r.Output)
		if reason == "" {
			reason = string(gate.StatusError)
		}
		lines = append(lines, fmt.Sprintf("gate %s misconfigured (%s) — fix the quest's check; not injected", r.Gate, reason))
	}
	sort.Strings(lines)
	return lines
}

func failingResults(results []gate.Result) []gate.Result {
	failures := make([]gate.Result, 0, len(results))
	for _, r := range results {
		if r.Status == gate.StatusFail {
			failures = append(failures, r)
		}
	}
	sort.Slice(failures, func(i, j int) bool {
		return failures[i].Gate < failures[j].Gate
	})
	return failures
}

func failureSignature(results []gate.Result) string {
	failures := failingResults(results)
	h := sha256.New()
	for _, r := range failures {
		fmt.Fprintf(h, "%s\x00%s\x00", r.Gate, boundedOutput(r.Output))
	}
	return hex.EncodeToString(h.Sum(nil))
}

func boundedOutput(output string) string {
	output = strings.TrimRight(output, "\n")
	if output == "" {
		return "(no output)"
	}
	lines := strings.Split(output, "\n")
	if len(lines) <= messageHeadLines+messageTailLines && len([]rune(output)) <= messageMaxChars {
		return output
	}

	var selected []string
	if len(lines) > messageHeadLines+messageTailLines {
		selected = append(selected, lines[:messageHeadLines]...)
		selected = append(selected, fmt.Sprintf("[... omitted %d lines ...]", len(lines)-messageHeadLines-messageTailLines))
		selected = append(selected, lines[len(lines)-messageTailLines:]...)
	} else {
		selected = lines
	}
	snippet := strings.Join(selected, "\n")
	runes := []rune(snippet)
	if len(runes) <= messageMaxChars {
		return snippet
	}
	head := messageMaxChars / 2
	tail := messageMaxChars - head
	return string(runes[:head]) + "\n[... output truncated ...]\n" + string(runes[len(runes)-tail:])
}

func oneLineReason(output string) string {
	reason := boundedOutput(output)
	if reason == "(no output)" {
		return ""
	}
	reason = strings.Join(strings.Fields(reason), " ")
	runes := []rune(reason)
	if len(runes) > 240 {
		return string(runes[:240]) + "..."
	}
	return reason
}

func cloneResults(results []gate.Result) []gate.Result {
	if len(results) == 0 {
		return nil
	}
	out := make([]gate.Result, len(results))
	copy(out, results)
	return out
}
