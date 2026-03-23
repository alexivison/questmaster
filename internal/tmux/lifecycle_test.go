package tmux

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// ---------------------------------------------------------------------------
// HasSession
// ---------------------------------------------------------------------------

func TestHasSession_Exists(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "has-session" || flagVal(args, "-t") != "party-abc" {
			t.Errorf("unexpected args: %v", args)
		}
		return "", nil
	})
	c := NewClient(m)

	ok, err := c.HasSession(t.Context(), "party-abc")
	if err != nil {
		t.Fatalf("HasSession: %v", err)
	}
	if !ok {
		t.Error("expected true for existing session")
	}
}

func TestHasSession_NotFound(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	ok, err := c.HasSession(t.Context(), "party-gone")
	if err != nil {
		t.Fatalf("HasSession: %v", err)
	}
	if ok {
		t.Error("expected false for missing session")
	}
}

func TestHasSession_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("connection refused")
	})
	c := NewClient(m)

	_, err := c.HasSession(t.Context(), "party-x")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// KillSession
// ---------------------------------------------------------------------------

func TestKillSession_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "kill-session" {
			t.Errorf("expected kill-session, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.KillSession(t.Context(), "party-abc"); err != nil {
		t.Fatalf("KillSession: %v", err)
	}
}

func TestKillSession_NotFound(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	// Should return nil when session doesn't exist
	if err := c.KillSession(t.Context(), "party-gone"); err != nil {
		t.Fatalf("KillSession of absent session: %v", err)
	}
}

func TestKillSession_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("server crashed")
	})
	c := NewClient(m)

	if err := c.KillSession(t.Context(), "party-x"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// NewSession
// ---------------------------------------------------------------------------

func TestNewSession_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "new-session" {
			t.Errorf("expected new-session, got %s", args[0])
		}
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-d") || !strings.Contains(joined, "-s") {
			t.Errorf("missing expected flags: %v", args)
		}
		if flagVal(args, "-s") != "party-new" {
			t.Errorf("session name: got %q", flagVal(args, "-s"))
		}
		if flagVal(args, "-n") != "work" {
			t.Errorf("window name: got %q", flagVal(args, "-n"))
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "party-new", "work", "/tmp"); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
}

func TestNewSession_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("duplicate session")
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "party-dup", "work", "/tmp"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// runWithoutTMUX — falls back to standard Run for non-ExecRunner
// ---------------------------------------------------------------------------

func TestRunWithoutTMUX_MockFallback(t *testing.T) {
	t.Parallel()

	called := false
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		called = true
		if args[0] != "new-session" {
			t.Errorf("expected new-session, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	// Mock runner doesn't implement ExecRunner, so falls back to Run
	_, err := c.runWithoutTMUX(t.Context(), "new-session", "-d", "-s", "test")
	if err != nil {
		t.Fatalf("runWithoutTMUX: %v", err)
	}
	if !called {
		t.Error("expected mock Run to be called")
	}
}

// ---------------------------------------------------------------------------
// RespawnPane
// ---------------------------------------------------------------------------

func TestRespawnPane_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "respawn-pane" {
			t.Errorf("expected respawn-pane, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.RespawnPane(t.Context(), "party-s:0.0", "/tmp", "bash"); err != nil {
		t.Fatalf("RespawnPane: %v", err)
	}
}

func TestRespawnPane_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane dead")
	})
	c := NewClient(m)

	if err := c.RespawnPane(t.Context(), "party-s:0.0", "/tmp", "bash"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SplitWindow
// ---------------------------------------------------------------------------

func TestSplitWindow_Horizontal(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-h") {
			t.Error("expected -h flag for horizontal split")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SplitWindow(t.Context(), "party-s:0.0", "/tmp", "bash", true); err != nil {
		t.Fatalf("SplitWindow: %v", err)
	}
}

func TestSplitWindow_Vertical(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "-h") {
			t.Error("unexpected -h flag for vertical split")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SplitWindow(t.Context(), "party-s:0.0", "/tmp", "bash", false); err != nil {
		t.Fatalf("SplitWindow: %v", err)
	}
}

func TestSplitWindow_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("no space")
	})
	c := NewClient(m)

	if err := c.SplitWindow(t.Context(), "party-s:0.0", "/tmp", "bash", true); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// NewWindow
// ---------------------------------------------------------------------------

func TestNewWindow_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "new-window" {
			t.Errorf("expected new-window, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.NewWindow(t.Context(), "party-s", "work", "/tmp"); err != nil {
		t.Fatalf("NewWindow: %v", err)
	}
}

func TestNewWindow_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("session gone")
	})
	c := NewClient(m)

	if err := c.NewWindow(t.Context(), "party-s", "work", "/tmp"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// RenameWindow
// ---------------------------------------------------------------------------

func TestRenameWindow_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "rename-window" {
			t.Errorf("expected rename-window, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.RenameWindow(t.Context(), "party-s:0", "codex"); err != nil {
		t.Fatalf("RenameWindow: %v", err)
	}
}

// ---------------------------------------------------------------------------
// SelectPane
// ---------------------------------------------------------------------------

func TestSelectPane_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "select-pane" {
			t.Errorf("expected select-pane, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SelectPane(t.Context(), "party-s:0.1"); err != nil {
		t.Fatalf("SelectPane: %v", err)
	}
}

func TestSelectPane_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane not found")
	})
	c := NewClient(m)

	if err := c.SelectPane(t.Context(), "party-s:0.9"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SelectPaneTitle
// ---------------------------------------------------------------------------

func TestSelectPaneTitle_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "select-pane" {
			t.Errorf("expected select-pane, got %s", args[0])
		}
		if flagVal(args, "-T") != "The Paladin" {
			t.Errorf("title: got %q", flagVal(args, "-T"))
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SelectPaneTitle(t.Context(), "party-s:0.1", "The Paladin"); err != nil {
		t.Fatalf("SelectPaneTitle: %v", err)
	}
}

// ---------------------------------------------------------------------------
// SelectWindow
// ---------------------------------------------------------------------------

func TestSelectWindow_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "select-window" {
			t.Errorf("expected select-window, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SelectWindow(t.Context(), "party-s:1"); err != nil {
		t.Fatalf("SelectWindow: %v", err)
	}
}

// ---------------------------------------------------------------------------
// SetPaneOption / SetWindowOption / SetSessionOption
// ---------------------------------------------------------------------------

func TestSetPaneOption_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-p") {
			t.Error("expected -p flag for pane option")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetPaneOption(t.Context(), "party-s:0.0", "@party_role", "codex"); err != nil {
		t.Fatalf("SetPaneOption: %v", err)
	}
}

func TestSetWindowOption_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-w") {
			t.Error("expected -w flag for window option")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetWindowOption(t.Context(), "party-s:0", "pane-border-status", "top"); err != nil {
		t.Fatalf("SetWindowOption: %v", err)
	}
}

func TestSetSessionOption_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "set-option" {
			t.Errorf("expected set-option, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetSessionOption(t.Context(), "party-s", "status-left", "hello"); err != nil {
		t.Fatalf("SetSessionOption: %v", err)
	}
}

func TestSetPaneOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetPaneOption(t.Context(), "party-s:0.0", "bad", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSetWindowOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetWindowOption(t.Context(), "party-s:0", "bad", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSetSessionOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetSessionOption(t.Context(), "party-s", "bad", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SetEnvironment
// ---------------------------------------------------------------------------

func TestSetEnvironment_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "set-environment" {
			t.Errorf("expected set-environment, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetEnvironment(t.Context(), "party-s", "KEY", "val"); err != nil {
		t.Fatalf("SetEnvironment: %v", err)
	}
}

func TestSetEnvironment_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("session gone")
	})
	c := NewClient(m)

	if err := c.SetEnvironment(t.Context(), "party-s", "KEY", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// UnsetEnvironment
// ---------------------------------------------------------------------------

func TestUnsetEnvironment_Session(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, "-g") {
			t.Error("unexpected -g flag for session unset")
		}
		if !strings.Contains(joined, "-u") {
			t.Error("expected -u flag")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "party-s", "KEY"); err != nil {
		t.Fatalf("UnsetEnvironment: %v", err)
	}
}

func TestUnsetEnvironment_Global(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-g") {
			t.Error("expected -g flag for global unset")
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "", "KEY"); err != nil {
		t.Fatalf("UnsetEnvironment global: %v", err)
	}
}

func TestUnsetEnvironment_NotSet(t *testing.T) {
	t.Parallel()

	// Non-zero exit (var not set) → nil error
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "party-s", "MISSING"); err != nil {
		t.Fatalf("expected nil for absent var, got: %v", err)
	}
}

func TestUnsetEnvironment_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("server crashed")
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "party-s", "KEY"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// ShowEnvironment
// ---------------------------------------------------------------------------

func TestShowEnvironment_Found(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "MY_KEY=hello world", nil
	})
	c := NewClient(m)

	val, ok, err := c.ShowEnvironment(t.Context(), "party-s", "MY_KEY")
	if err != nil {
		t.Fatalf("ShowEnvironment: %v", err)
	}
	if !ok {
		t.Error("expected ok=true")
	}
	if val != "hello world" {
		t.Errorf("value: got %q, want %q", val, "hello world")
	}
}

func TestShowEnvironment_NotSet(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	_, ok, err := c.ShowEnvironment(t.Context(), "party-s", "MISSING")
	if err != nil {
		t.Fatalf("ShowEnvironment: %v", err)
	}
	if ok {
		t.Error("expected ok=false for missing var")
	}
}

func TestShowEnvironment_Unset(t *testing.T) {
	t.Parallel()

	// Unset vars show as "-KEY"
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "-MY_KEY", nil
	})
	c := NewClient(m)

	_, ok, err := c.ShowEnvironment(t.Context(), "party-s", "MY_KEY")
	if err != nil {
		t.Fatalf("ShowEnvironment: %v", err)
	}
	if ok {
		t.Error("expected ok=false for unset var")
	}
}

func TestShowEnvironment_NoEquals(t *testing.T) {
	t.Parallel()

	// Malformed output with no = sign
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "WEIRDFORMAT", nil
	})
	c := NewClient(m)

	val, ok, err := c.ShowEnvironment(t.Context(), "party-s", "WEIRDFORMAT")
	if err != nil {
		t.Fatalf("ShowEnvironment: %v", err)
	}
	if ok {
		t.Error("expected ok=false for malformed output")
	}
	if val != "" {
		t.Errorf("expected empty val, got %q", val)
	}
}

func TestShowEnvironment_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("crash")
	})
	c := NewClient(m)

	_, _, err := c.ShowEnvironment(t.Context(), "party-s", "KEY")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SetHook
// ---------------------------------------------------------------------------

func TestSetHook_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "set-hook" {
			t.Errorf("expected set-hook, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetHook(t.Context(), "party-s", "session-closed", "run-shell 'cleanup'"); err != nil {
		t.Fatalf("SetHook: %v", err)
	}
}

func TestSetHook_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad hook")
	})
	c := NewClient(m)

	if err := c.SetHook(t.Context(), "party-s", "bad", "cmd"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SwitchClient
// ---------------------------------------------------------------------------

func TestSwitchClient_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "switch-client" {
			t.Errorf("expected switch-client, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SwitchClient(t.Context(), "party-new"); err != nil {
		t.Fatalf("SwitchClient: %v", err)
	}
}

func TestSwitchClient_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("no client")
	})
	c := NewClient(m)

	if err := c.SwitchClient(t.Context(), "party-x"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SwitchClientWithFallback
// ---------------------------------------------------------------------------

func TestSwitchClientWithFallback_DirectSuccess(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "switch-client" {
			t.Errorf("expected switch-client, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SwitchClientWithFallback(t.Context(), "party-new"); err != nil {
		t.Fatalf("SwitchClientWithFallback: %v", err)
	}
	if len(m.calls) != 1 {
		t.Errorf("expected 1 call (direct switch), got %d", len(m.calls))
	}
}

func TestSwitchClientWithFallback_FallbackToExplicitClient(t *testing.T) {
	t.Parallel()

	callNum := 0
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		callNum++
		switch callNum {
		case 1:
			// First switch-client fails (popup context — no client TTY)
			if args[0] != "switch-client" {
				t.Errorf("call 1: expected switch-client, got %s", args[0])
			}
			return "", &ExitError{Code: 1}
		case 2:
			// list-clients to discover available clients
			if args[0] != "list-clients" {
				t.Errorf("call 2: expected list-clients, got %s", args[0])
			}
			return "/dev/ttys001", nil
		case 3:
			// Retry switch-client with explicit -c flag
			if args[0] != "switch-client" {
				t.Errorf("call 3: expected switch-client, got %s", args[0])
			}
			if flagVal(args, "-c") != "/dev/ttys001" {
				t.Errorf("call 3: expected -c /dev/ttys001, got %q", flagVal(args, "-c"))
			}
			if flagVal(args, "-t") != "party-popup" {
				t.Errorf("call 3: expected -t party-popup, got %q", flagVal(args, "-t"))
			}
			return "", nil
		default:
			t.Fatalf("unexpected call %d: %v", callNum, args)
			return "", nil
		}
	})
	c := NewClient(m)

	if err := c.SwitchClientWithFallback(t.Context(), "party-popup"); err != nil {
		t.Fatalf("SwitchClientWithFallback: %v", err)
	}
	if callNum != 3 {
		t.Errorf("expected 3 calls (switch, list, switch -c), got %d", callNum)
	}
}

func TestSwitchClientWithFallback_NoClients(t *testing.T) {
	t.Parallel()

	callNum := 0
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		callNum++
		switch callNum {
		case 1:
			return "", &ExitError{Code: 1}
		case 2:
			// list-clients returns empty (no clients)
			return "", nil
		default:
			t.Fatalf("unexpected call %d", callNum)
			return "", nil
		}
	})
	c := NewClient(m)

	err := c.SwitchClientWithFallback(t.Context(), "party-x")
	if err == nil {
		t.Fatal("expected error when no clients available")
	}
}

func TestSwitchClientWithFallback_NonExitError_NeverFallback(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("connection refused")
	})
	c := NewClient(m)

	err := c.SwitchClientWithFallback(t.Context(), "party-x")
	if err == nil {
		t.Fatal("expected error propagation for non-ExitError")
	}
	// Should NOT attempt list-clients for non-ExitError
	if len(m.calls) != 1 {
		t.Errorf("expected 1 call (no fallback for non-ExitError), got %d", len(m.calls))
	}
}

func TestSwitchClientWithFallback_MultipleClients_UsesFirst(t *testing.T) {
	t.Parallel()

	callNum := 0
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		callNum++
		switch callNum {
		case 1:
			return "", &ExitError{Code: 1}
		case 2:
			return "/dev/ttys001\n/dev/ttys002\n/dev/ttys003", nil
		case 3:
			if flagVal(args, "-c") != "/dev/ttys001" {
				t.Errorf("expected first client, got %q", flagVal(args, "-c"))
			}
			return "", nil
		default:
			t.Fatalf("unexpected call %d", callNum)
			return "", nil
		}
	})
	c := NewClient(m)

	if err := c.SwitchClientWithFallback(t.Context(), "party-multi"); err != nil {
		t.Fatalf("SwitchClientWithFallback: %v", err)
	}
}

// ---------------------------------------------------------------------------
// filterEnv
// ---------------------------------------------------------------------------

func TestFilterEnv(t *testing.T) {
	t.Parallel()

	env := []string{"HOME=/home/user", "TMUX=/tmp/tmux-1000/default,12345,0", "PATH=/usr/bin"}
	filtered := filterEnv(env, "TMUX")

	if len(filtered) != 2 {
		t.Fatalf("len: got %d, want 2", len(filtered))
	}
	for _, e := range filtered {
		if strings.HasPrefix(e, "TMUX=") {
			t.Error("TMUX should have been filtered")
		}
	}
}

func TestFilterEnv_NoMatch(t *testing.T) {
	t.Parallel()

	env := []string{"HOME=/home/user", "PATH=/usr/bin"}
	filtered := filterEnv(env, "TMUX")

	if len(filtered) != 2 {
		t.Fatalf("len: got %d, want 2 (nothing filtered)", len(filtered))
	}
}

// flagVal helper for test assertions (same as in tmux_test.go's context)
func flagVal(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}
