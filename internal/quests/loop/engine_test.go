package loop

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
)

func TestEngineRunOutcomes(t *testing.T) {
	base := time.Date(2026, 6, 4, 10, 0, 0, 0, time.UTC)
	tests := map[string]struct {
		checks      [][]gate.Result
		events      []Event
		config      Config
		wantKind    OutcomeKind
		wantReason  StopReason
		wantInjects int
	}{
		"fail fail pass injects twice then green": {
			checks: [][]gate.Result{
				{{Gate: "tests", Status: gate.StatusFail, Output: "first failure"}},
				{{Gate: "tests", Status: gate.StatusFail, Output: "second failure"}},
				{{Gate: "tests", Status: gate.StatusPass}},
			},
			events:      []Event{{Kind: EventDone}, {Kind: EventDone}, {Kind: EventDone}},
			config:      Config{MaxIters: 5, MaxWall: time.Hour, StuckAfter: 5},
			wantKind:    OutcomeGreen,
			wantInjects: 2,
		},
		"misconfigured pauses without injection": {
			checks: [][]gate.Result{
				{{Gate: "build", Status: gate.StatusError, Output: "missing tool"}},
			},
			events:      []Event{{Kind: EventDone}},
			config:      Config{MaxIters: 5, MaxWall: time.Hour, StuckAfter: 5},
			wantKind:    OutcomeMisconfigured,
			wantInjects: 0,
		},
		"unchanged failure signature stops as stuck": {
			checks: [][]gate.Result{
				{{Gate: "tests", Status: gate.StatusFail, Output: "same failure"}},
				{{Gate: "tests", Status: gate.StatusFail, Output: "same failure"}},
				{{Gate: "tests", Status: gate.StatusFail, Output: "same failure"}},
			},
			events:      []Event{{Kind: EventDone}, {Kind: EventDone}, {Kind: EventDone}},
			config:      Config{MaxIters: 5, MaxWall: time.Hour, StuckAfter: 3},
			wantKind:    OutcomeStopped,
			wantReason:  StopStuck,
			wantInjects: 2,
		},
		"max iterations stops before another injection": {
			checks: [][]gate.Result{
				{{Gate: "tests", Status: gate.StatusFail, Output: "first"}},
				{{Gate: "tests", Status: gate.StatusFail, Output: "second"}},
			},
			events:      []Event{{Kind: EventDone}, {Kind: EventDone}},
			config:      Config{MaxIters: 2, MaxWall: time.Hour, StuckAfter: 5},
			wantKind:    OutcomeStopped,
			wantReason:  StopBudget,
			wantInjects: 1,
		},
		"blocked pauses and does not inject": {
			checks: [][]gate.Result{
				{{Gate: "tests", Status: gate.StatusPass}},
			},
			events:      []Event{{Kind: EventBlocked}, {Kind: EventDone}},
			config:      Config{MaxIters: 5, MaxWall: time.Hour, StuckAfter: 5, BlockedTimeout: time.Hour},
			wantKind:    OutcomeGreen,
			wantInjects: 0,
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			source := scriptedSource(tc.events)
			var injects []string
			checkIdx := 0
			engine := Engine{
				Check: func(context.Context) ([]gate.Result, error) {
					if checkIdx >= len(tc.checks) {
						return nil, errors.New("unexpected check")
					}
					results := tc.checks[checkIdx]
					checkIdx++
					return results, nil
				},
				Inject: func(_ context.Context, msg string) error {
					injects = append(injects, msg)
					return nil
				},
				Events: source,
				Clock:  fakeClock{now: base},
				Config: tc.config,
			}

			got := engine.Run(context.Background())
			if got.Kind != tc.wantKind {
				t.Fatalf("outcome kind = %q, want %q", got.Kind, tc.wantKind)
			}
			if got.Reason != tc.wantReason {
				t.Fatalf("outcome reason = %q, want %q", got.Reason, tc.wantReason)
			}
			if len(injects) != tc.wantInjects {
				t.Fatalf("inject count = %d, want %d (%v)", len(injects), tc.wantInjects, injects)
			}
		})
	}
}

func TestEngineStopsAfterBlockedTimeout(t *testing.T) {
	events := make(chan Event, 1)
	events <- Event{Kind: EventBlocked}
	timeout := make(chan time.Time, 1)
	clock := controllableClock{
		now: baseTime(),
		after: func(d time.Duration) <-chan time.Time {
			if d != 5*time.Second {
				t.Fatalf("blocked timeout duration = %s, want 5s", d)
			}
			return timeout
		},
	}
	engine := Engine{
		Check: func(context.Context) ([]gate.Result, error) {
			t.Fatal("check must not run while blocked")
			return nil, nil
		},
		Inject: func(context.Context, string) error {
			t.Fatal("blocked timeout must not inject")
			return nil
		},
		Events: events,
		Clock:  clock,
		Config: Config{MaxIters: 5, StuckAfter: 5, BlockedTimeout: 5 * time.Second},
	}

	done := make(chan Outcome, 1)
	go func() {
		done <- engine.Run(context.Background())
	}()
	timeout <- baseTime().Add(5 * time.Second)

	select {
	case got := <-done:
		if got.Kind != OutcomeStopped || got.Reason != StopBlockedTimeout {
			t.Fatalf("outcome = %q/%q, want stopped/%q", got.Kind, got.Reason, StopBlockedTimeout)
		}
	case <-time.After(time.Second):
		t.Fatal("engine did not stop after blocked timeout")
	}
}

func TestFailureMessageGolden(t *testing.T) {
	msg := FailureMessage([]gate.Result{
		{Gate: "unit-tests", Status: gate.StatusFail, Output: numberedLines(30)},
	})
	want, err := os.ReadFile("testdata/failure_message.golden")
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if msg != strings.TrimRight(string(want), "\n") {
		t.Fatalf("failure message changed\nwant:\n%s\n\ngot:\n%s", string(want), msg)
	}
}

func TestFailureMessageIncludesFailureAndAvoidsGateStampingInstructions(t *testing.T) {
	msg := FailureMessage([]gate.Result{
		{Gate: "unit-tests", Status: gate.StatusFail, Output: numberedLines(40)},
	})
	if !strings.Contains(msg, "unit-tests") {
		t.Fatalf("message missing gate name:\n%s", msg)
	}
	if !strings.Contains(strings.ToLower(msg), "fix the work so the check passes") {
		t.Fatalf("message missing fix-work directive:\n%s", msg)
	}
	if !strings.Contains(msg, "[... omitted") {
		t.Fatalf("message did not bound head+tail output:\n%s", msg)
	}
	for _, forbidden := range []string{"pass the gate", "pass gates", "approve", "mark done", "set status"} {
		if strings.Contains(strings.ToLower(msg), forbidden) {
			t.Fatalf("message contains forbidden phrase %q:\n%s", forbidden, msg)
		}
	}
}

func TestMisconfiguredLineExact(t *testing.T) {
	lines := MisconfiguredLines([]gate.Result{
		{Gate: "build", Status: gate.StatusError, Output: "unsupported check badprefix:thing (this stage runs cmd:<shell> only)"},
	})
	want := "gate build misconfigured (unsupported check badprefix:thing (this stage runs cmd:<shell> only)) — fix the quest's check; not injected"
	if len(lines) != 1 || lines[0] != want {
		t.Fatalf("misconfigured lines = %#v, want %#v", lines, []string{want})
	}
}

func scriptedSource(events []Event) <-chan Event {
	ch := make(chan Event, len(events))
	for _, ev := range events {
		ch <- ev
	}
	return ch
}

func numberedLines(n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		if i < 10 {
			b.WriteString("L")
		} else {
			b.WriteString("L")
		}
		b.WriteString(string(rune('0' + i/10)))
		b.WriteString(string(rune('0' + i%10)))
		b.WriteByte('\n')
	}
	return b.String()
}

func baseTime() time.Time {
	return time.Date(2026, 6, 4, 10, 0, 0, 0, time.UTC)
}

type fakeClock struct {
	now time.Time
}

func (c fakeClock) Now() time.Time { return c.now }

func (c fakeClock) After(time.Duration) <-chan time.Time {
	ch := make(chan time.Time)
	return ch
}

type controllableClock struct {
	now   time.Time
	after func(time.Duration) <-chan time.Time
}

func (c controllableClock) Now() time.Time { return c.now }

func (c controllableClock) After(d time.Duration) <-chan time.Time {
	return c.after(d)
}
