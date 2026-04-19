package tmux

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Mock runner
// ---------------------------------------------------------------------------

type call struct {
	args []string
}

type mockRunner struct {
	fn    func(ctx context.Context, args ...string) (string, error)
	calls []call
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	m.calls = append(m.calls, call{args: args})
	return m.fn(ctx, args...)
}

func newMock(fn func(ctx context.Context, args ...string) (string, error)) *mockRunner {
	return &mockRunner{fn: fn}
}

// ---------------------------------------------------------------------------
// Pane.Target
// ---------------------------------------------------------------------------

func TestPane_Target(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		pane Pane
		want string
	}{
		"standard": {
			pane: Pane{SessionName: "party-abc", WindowIndex: 1, PaneIndex: 2},
			want: "party-abc:1.2",
		},
		"codex window": {
			pane: Pane{SessionName: "party-x", WindowIndex: 0, PaneIndex: 0},
			want: "party-x:0.0",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := tc.pane.Target()
			if got != tc.want {
				t.Errorf("Target(): got %q, want %q", got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// CurrentSessionName
// ---------------------------------------------------------------------------

func TestCurrentSessionName_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "display-message" {
			t.Errorf("expected display-message, got %s", args[0])
		}
		return "party-abc", nil
	})
	c := NewClient(m)

	name, err := c.CurrentSessionName(t.Context())
	if err != nil {
		t.Fatalf("CurrentSessionName: %v", err)
	}
	if name != "party-abc" {
		t.Errorf("got %q, want %q", name, "party-abc")
	}
}

func TestCurrentSessionName_UsesTMUXPaneTarget(t *testing.T) {
	t.Setenv("TMUX_PANE", "%42")
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if got := strings.Join(args, " "); !strings.Contains(got, "-t %42") {
			t.Fatalf("expected TMUX_PANE target in args, got %v", args)
		}
		return "party-pane", nil
	})
	c := NewClient(m)

	name, err := c.CurrentSessionName(t.Context())
	if err != nil {
		t.Fatalf("CurrentSessionName: %v", err)
	}
	if name != "party-pane" {
		t.Fatalf("got %q, want %q", name, "party-pane")
	}
}

func TestCurrentSessionName_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	_, err := c.CurrentSessionName(t.Context())
	if err == nil {
		t.Fatal("expected error when tmux fails")
	}
}

// ---------------------------------------------------------------------------
// ListSessions
// ---------------------------------------------------------------------------

func TestListSessions_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "party-abc\nparty-def\nother-session", nil
	})
	c := NewClient(m)

	sessions, err := c.ListSessions(t.Context())
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if len(sessions) != 3 {
		t.Fatalf("count: got %d, want 3", len(sessions))
	}
	if sessions[0] != "party-abc" || sessions[1] != "party-def" || sessions[2] != "other-session" {
		t.Errorf("sessions: got %v", sessions)
	}
}

func TestListSessions_Empty(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	sessions, err := c.ListSessions(t.Context())
	if err != nil {
		t.Fatalf("ListSessions: %v", err)
	}
	if sessions != nil {
		t.Fatalf("sessions: got %v, want nil", sessions)
	}
}

func TestListSessions_NoServer(t *testing.T) {
	t.Parallel()

	// tmux ran but exited non-zero (no server) → treat as empty
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	sessions, err := c.ListSessions(t.Context())
	if err != nil {
		t.Fatalf("expected nil error for no-server, got: %v", err)
	}
	if sessions != nil {
		t.Fatalf("sessions: got %v, want nil", sessions)
	}
}

func TestListSessions_MissingBinary(t *testing.T) {
	t.Parallel()

	// tmux binary not found → propagate error
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("exec: \"tmux\": executable file not found in $PATH")
	})
	c := NewClient(m)

	_, err := c.ListSessions(t.Context())
	if err == nil {
		t.Fatal("expected error for missing binary, got nil")
	}
}

func TestListSessions_ContextCanceled(t *testing.T) {
	t.Parallel()

	ctx, cancel := context.WithCancel(t.Context())
	cancel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", context.Canceled
	})
	c := NewClient(m)

	_, err := c.ListSessions(ctx)
	if err == nil {
		t.Fatal("expected error for canceled context, got nil")
	}
}

// ---------------------------------------------------------------------------
// ListSessionDetails
// ---------------------------------------------------------------------------

func TestListSessionDetails_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "party-abc\t/tmp/a\nmy-dev\t/home/user/code\nscratchy\t/tmp/s", nil
	})
	c := NewClient(m)

	infos, err := c.ListSessionDetails(t.Context())
	if err != nil {
		t.Fatalf("ListSessionDetails: %v", err)
	}
	if len(infos) != 3 {
		t.Fatalf("count: got %d, want 3", len(infos))
	}
	if infos[0].Name != "party-abc" || infos[0].Cwd != "/tmp/a" {
		t.Errorf("infos[0]: got %+v", infos[0])
	}
	if infos[1].Name != "my-dev" || infos[1].Cwd != "/home/user/code" {
		t.Errorf("infos[1]: got %+v", infos[1])
	}
}

func TestListSessionDetails_Empty(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	infos, err := c.ListSessionDetails(t.Context())
	if err != nil {
		t.Fatalf("ListSessionDetails: %v", err)
	}
	if infos != nil {
		t.Fatalf("infos: got %v, want nil", infos)
	}
}

func TestListSessionDetails_TrailingNewline(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "my-dev\t/home/user/code\n", nil // trailing newline like real tmux
	})
	c := NewClient(m)

	infos, err := c.ListSessionDetails(t.Context())
	if err != nil {
		t.Fatalf("ListSessionDetails: %v", err)
	}
	if len(infos) != 1 {
		t.Fatalf("count: got %d, want 1 (trailing newline should not produce empty entry)", len(infos))
	}
	if infos[0].Name != "my-dev" {
		t.Errorf("infos[0].Name: got %q, want %q", infos[0].Name, "my-dev")
	}
}

func TestListSessionDetails_NoServer(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	infos, err := c.ListSessionDetails(t.Context())
	if err != nil {
		t.Fatalf("expected nil error for no-server, got: %v", err)
	}
	if infos != nil {
		t.Fatalf("infos: got %v, want nil", infos)
	}
}

// ---------------------------------------------------------------------------
// ListPanes
// ---------------------------------------------------------------------------

func TestListPanes_MultipleWindows(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n0 1 claude\n1 0 shell\n1 1", nil
	})
	c := NewClient(m)

	panes, err := c.ListPanes(t.Context(), "party-test")
	if err != nil {
		t.Fatalf("ListPanes: %v", err)
	}
	if len(panes) != 4 {
		t.Fatalf("count: got %d, want 4", len(panes))
	}

	// Verify first pane
	if panes[0].SessionName != "party-test" || panes[0].WindowIndex != 0 ||
		panes[0].PaneIndex != 0 || panes[0].Role != "codex" {
		t.Errorf("pane[0]: got %+v", panes[0])
	}
	// Pane without role
	if panes[3].Role != "" {
		t.Errorf("pane[3].Role: got %q, want empty", panes[3].Role)
	}
}

func TestListPanes_Empty(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	panes, err := c.ListPanes(t.Context(), "party-empty")
	if err != nil {
		t.Fatalf("ListPanes: %v", err)
	}
	if panes != nil {
		t.Fatalf("panes: got %v, want nil", panes)
	}
}

func TestListPanes_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("session not found")
	})
	c := NewClient(m)

	_, err := c.ListPanes(t.Context(), "party-gone")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestListPanes_InvalidFormat(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "not_a_number 0 role", nil
	})
	c := NewClient(m)

	_, err := c.ListPanes(t.Context(), "party-bad")
	if err == nil {
		t.Fatal("expected parse error, got nil")
	}
}

// ---------------------------------------------------------------------------
// ResolveRole
// ---------------------------------------------------------------------------

func TestResolveRole_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n0 1 claude\n1 0 shell", nil
	})
	c := NewClient(m)

	target, err := c.ResolveRole(t.Context(), "party-s", "claude", -1)
	if err != nil {
		t.Fatalf("ResolveRole: %v", err)
	}
	if target != "party-s:0.1" {
		t.Errorf("target: got %q, want %q", target, "party-s:0.1")
	}
}

func TestResolveRole_PreferredWindow(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n0 1 claude\n1 0 claude", nil
	})
	c := NewClient(m)

	// Preferred window 1 — should find claude in window 1
	target, err := c.ResolveRole(t.Context(), "party-s", "claude", 1)
	if err != nil {
		t.Fatalf("ResolveRole preferred=1: %v", err)
	}
	if target != "party-s:1.0" {
		t.Errorf("target: got %q, want %q", target, "party-s:1.0")
	}

	// Preferred window 0 — should find claude in window 0
	target, err = c.ResolveRole(t.Context(), "party-s", "claude", 0)
	if err != nil {
		t.Fatalf("ResolveRole preferred=0: %v", err)
	}
	if target != "party-s:0.1" {
		t.Errorf("target: got %q, want %q", target, "party-s:0.1")
	}
}

func TestResolveRole_DuplicateAcrossWindows_NoPreference(t *testing.T) {
	t.Parallel()

	// Duplicate roles across windows with no preference — returns lowest window index
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 claude\n1 0 claude", nil
	})
	c := NewClient(m)

	target, err := c.ResolveRole(t.Context(), "party-s", "claude", -1)
	if err != nil {
		t.Fatalf("ResolveRole: %v", err)
	}
	if target != "party-s:0.0" {
		t.Errorf("target: got %q, want %q", target, "party-s:0.0")
	}
}

func TestResolveRole_AmbiguousWindowBlocksLaterMatch(t *testing.T) {
	t.Parallel()

	// Window 1 has ambiguous claude, window 2 has single claude.
	// Sequential search should stop at window 1 with ErrRoleAmbiguous,
	// NOT skip to window 2 (matching party-lib.sh contract).
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n1 0 claude\n1 1 claude\n2 0 claude", nil
	})
	c := NewClient(m)

	_, err := c.ResolveRole(t.Context(), "party-s", "claude", -1)
	if err == nil {
		t.Fatal("expected ErrRoleAmbiguous, got nil")
	}
	if !errors.Is(err, ErrRoleAmbiguous) {
		t.Errorf("error: got %v, want ErrRoleAmbiguous", err)
	}
}

func TestResolveRole_AmbiguousWithinWindow(t *testing.T) {
	t.Parallel()

	// Exercises resolveInWindow path (preferredWindow=0 hits the preferred-window shortcut).
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 claude\n0 1 claude", nil
	})
	c := NewClient(m)

	_, err := c.ResolveRole(t.Context(), "party-s", "claude", 0)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrRoleAmbiguous) {
		t.Errorf("error: got %v, want ErrRoleAmbiguous", err)
	}
}

func TestResolveRole_AmbiguousWithinWindow_NoPreference(t *testing.T) {
	t.Parallel()

	// Exercises groupByWindow fallback path (preferredWindow=-1 skips preferred-window shortcut).
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 claude\n0 1 claude", nil
	})
	c := NewClient(m)

	_, err := c.ResolveRole(t.Context(), "party-s", "claude", -1)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrRoleAmbiguous) {
		t.Errorf("error: got %v, want ErrRoleAmbiguous", err)
	}
}

func TestResolveRole_NotFound(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n0 1 claude", nil
	})
	c := NewClient(m)

	_, err := c.ResolveRole(t.Context(), "party-s", "tracker", -1)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrRoleNotFound) {
		t.Errorf("error: got %v, want ErrRoleNotFound", err)
	}
}

func TestResolveRole_PreferredWindowFallback(t *testing.T) {
	t.Parallel()

	// Role not in preferred window, falls back to other windows
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0 0 codex\n1 0 claude", nil
	})
	c := NewClient(m)

	target, err := c.ResolveRole(t.Context(), "party-s", "claude", 0)
	if err != nil {
		t.Fatalf("ResolveRole: %v", err)
	}
	if target != "party-s:1.0" {
		t.Errorf("target: got %q, want %q", target, "party-s:1.0")
	}
}

func TestResolveRole_EmptySession(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	_, err := c.ResolveRole(t.Context(), "party-empty", "claude", -1)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !errors.Is(err, ErrRoleNotFound) {
		t.Errorf("error: got %v, want ErrRoleNotFound", err)
	}
}

// ---------------------------------------------------------------------------
// IsPaneIdle
// ---------------------------------------------------------------------------

func TestIsPaneIdle_Idle(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "0", nil
	})
	c := NewClient(m)

	idle, err := c.IsPaneIdle(t.Context(), "party-s:0.0")
	if err != nil {
		t.Fatalf("IsPaneIdle: %v", err)
	}
	if !idle {
		t.Error("expected idle, got not idle")
	}
}

func TestIsPaneIdle_InCopyMode(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "1", nil
	})
	c := NewClient(m)

	idle, err := c.IsPaneIdle(t.Context(), "party-s:0.0")
	if err != nil {
		t.Fatalf("IsPaneIdle: %v", err)
	}
	if idle {
		t.Error("expected not idle, got idle")
	}
}

func TestIsPaneIdle_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane dead")
	})
	c := NewClient(m)

	_, err := c.IsPaneIdle(t.Context(), "party-s:0.0")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// Send
// ---------------------------------------------------------------------------

func TestSend_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return "0", nil // idle
		}
		return "", nil // send-keys success
	})
	c := NewClient(m)

	result := c.Send(t.Context(), "party-s:0.1", "hello world")
	if !result.Delivered {
		t.Fatalf("expected delivered, got error: %v", result.Err)
	}
	if result.Target != "party-s:0.1" {
		t.Errorf("target: got %q, want %q", result.Target, "party-s:0.1")
	}
}

func TestSend_VerifiesCommandArgs(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return "0", nil
		}
		return "", nil
	})
	c := NewClient(m)

	c.Send(t.Context(), "party-s:0.1", "test msg")

	// Expect 3 calls: display-message, send-keys -l, send-keys Enter
	if len(m.calls) != 3 {
		t.Fatalf("call count: got %d, want 3", len(m.calls))
	}

	// Verify send-keys -l call includes -- separator and literal text
	sendCall := m.calls[1]
	joined := strings.Join(sendCall.args, " ")
	if !strings.Contains(joined, "-l") || !strings.Contains(joined, "--") || !strings.Contains(joined, "test msg") {
		t.Errorf("send-keys call: got %v", sendCall.args)
	}

	// Verify Enter key call
	enterCall := m.calls[2]
	if enterCall.args[len(enterCall.args)-1] != "Enter" {
		t.Errorf("enter call: got %v", enterCall.args)
	}
}

func TestSend_Timeout(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "1", nil // always in copy mode
	})
	c := NewClient(m)
	c.SendTimeout = 200 * time.Millisecond

	result := c.Send(t.Context(), "party-s:0.0", "blocked")
	if result.Delivered {
		t.Fatal("expected timeout, got delivered")
	}
	if !errors.Is(result.Err, ErrSendTimeout) {
		t.Errorf("error: got %v, want ErrSendTimeout", result.Err)
	}
}

func TestSend_IdleCheckError(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane gone")
	})
	c := NewClient(m)

	result := c.Send(t.Context(), "party-s:0.0", "msg")
	if result.Delivered {
		t.Fatal("expected error, got delivered")
	}
	if result.Err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSend_SendKeysError(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return "0", nil // idle
		}
		return "", errors.New("send failed")
	})
	c := NewClient(m)

	result := c.Send(t.Context(), "party-s:0.1", "msg")
	if result.Delivered {
		t.Fatal("expected error, got delivered")
	}
}

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

func TestCapture_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "line1\nline2\nline3", nil
	})
	c := NewClient(m)

	out, err := c.Capture(t.Context(), "party-s:0.1", 500)
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if out != "line1\nline2\nline3" {
		t.Errorf("output: got %q", out)
	}
}

func TestCapture_VerifiesArgs(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	c.Capture(t.Context(), "party-s:1.0", 200)

	if len(m.calls) != 1 {
		t.Fatalf("call count: got %d, want 1", len(m.calls))
	}

	args := m.calls[0].args
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "capture-pane") ||
		!strings.Contains(joined, "-t") ||
		!strings.Contains(joined, "party-s:1.0") ||
		!strings.Contains(joined, "-S") ||
		!strings.Contains(joined, "-200") {
		t.Errorf("args: got %v", args)
	}
}

func TestCapture_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane dead")
	})
	c := NewClient(m)

	_, err := c.Capture(t.Context(), "party-s:0.0", 100)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SplitWindow
// ---------------------------------------------------------------------------

func TestSplitWindow(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		horizontal bool
		pct        []int
		wantArgs   []string
	}{
		"horizontal no pct": {
			horizontal: true,
			wantArgs:   []string{"split-window", "-h", "-t", "s:0.0", "-c", "/tmp", "bash"},
		},
		"vertical no pct": {
			horizontal: false,
			wantArgs:   []string{"split-window", "-t", "s:0.0", "-c", "/tmp", "bash"},
		},
		"horizontal with pct": {
			horizontal: true,
			pct:        []int{80},
			wantArgs:   []string{"split-window", "-h", "-p", "80", "-t", "s:0.0", "-c", "/tmp", "bash"},
		},
		"pct zero skipped": {
			horizontal: true,
			pct:        []int{0},
			wantArgs:   []string{"split-window", "-h", "-t", "s:0.0", "-c", "/tmp", "bash"},
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			m := newMock(func(_ context.Context, _ ...string) (string, error) {
				return "", nil
			})
			c := NewClient(m)

			err := c.SplitWindow(t.Context(), "s:0.0", "/tmp", "bash", tc.horizontal, tc.pct...)
			if err != nil {
				t.Fatalf("SplitWindow: %v", err)
			}
			if len(m.calls) != 1 {
				t.Fatalf("call count: got %d, want 1", len(m.calls))
			}
			got := m.calls[0].args
			if len(got) != len(tc.wantArgs) {
				t.Fatalf("args len: got %d %v, want %d %v", len(got), got, len(tc.wantArgs), tc.wantArgs)
			}
			for i := range got {
				if got[i] != tc.wantArgs[i] {
					t.Errorf("args[%d]: got %q, want %q", i, got[i], tc.wantArgs[i])
				}
			}
		})
	}
}

func TestSplitWindow_EmptyCmd(t *testing.T) {
	t.Parallel()
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	if err := c.SplitWindow(t.Context(), "s:0.0", "/tmp", "", true); err != nil {
		t.Fatalf("SplitWindow: %v", err)
	}
	if len(m.calls) != 1 {
		t.Fatalf("call count: got %d, want 1", len(m.calls))
	}
	wantArgs := []string{"split-window", "-h", "-t", "s:0.0", "-c", "/tmp"}
	got := m.calls[0].args
	if len(got) != len(wantArgs) {
		t.Fatalf("args len: got %d %v, want %d %v", len(got), got, len(wantArgs), wantArgs)
	}
	for i := range got {
		if got[i] != wantArgs[i] {
			t.Errorf("args[%d]: got %q, want %q", i, got[i], wantArgs[i])
		}
	}
}

// ---------------------------------------------------------------------------
// Popup helpers
// ---------------------------------------------------------------------------

func TestPopupArgs(t *testing.T) {
	t.Parallel()

	args := PopupArgs("party-s:0.0", 60, 70, "bash")
	want := []string{"display-popup", "-E", "-t", "party-s:0.0", "-w", "60%", "-h", "70%", "bash"}
	if len(args) != len(want) {
		t.Fatalf("len: got %d, want %d", len(args), len(want))
	}
	for i := range args {
		if args[i] != want[i] {
			t.Errorf("args[%d]: got %q, want %q", i, args[i], want[i])
		}
	}
}

// ---------------------------------------------------------------------------
// Window-management helpers
// ---------------------------------------------------------------------------

func TestCompanionTarget(t *testing.T) {
	t.Parallel()

	got := CompanionTarget("party-abc")
	if got != "party-abc:0" {
		t.Errorf("CompanionTarget: got %q, want %q", got, "party-abc:0")
	}
}

func TestWorkspaceTarget(t *testing.T) {
	t.Parallel()

	got := WorkspaceTarget("party-abc")
	if got != "party-abc:1" {
		t.Errorf("WorkspaceTarget: got %q, want %q", got, "party-abc:1")
	}
}

func TestCapture_InvalidLines(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	_, err := c.Capture(t.Context(), "party-s:0.0", 0)
	if err == nil {
		t.Fatal("expected error for zero lines, got nil")
	}

	_, err = c.Capture(t.Context(), "party-s:0.0", -5)
	if err == nil {
		t.Fatal("expected error for negative lines, got nil")
	}
}
