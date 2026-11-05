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
		if args[0] != "has-session" || flagVal(args, "-t") != "=qm-abc:" {
			t.Errorf("unexpected args: %v", args)
		}
		return "", nil
	})
	c := NewClient(m)

	ok, err := c.HasSession(t.Context(), "qm-abc")
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

	ok, err := c.HasSession(t.Context(), "qm-gone")
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

	_, err := c.HasSession(t.Context(), "qm-x")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestHasSession_NoServerIsBenign(t *testing.T) {
	t.Parallel()

	// "No such file or directory" means no tmux server exists yet.
	// This is functionally "session not found", not a transport error.
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-501/default (No such file or directory)"}
	})
	c := NewClient(m)

	ok, err := c.HasSession(t.Context(), "qm-x")
	if err != nil {
		t.Fatalf("expected nil error for benign no-server case, got: %v", err)
	}
	if ok {
		t.Error("expected false for no-server case")
	}
}

func TestHasSession_ConnectionError(t *testing.T) {
	t.Parallel()

	// ExitError with real transport-error stderr should propagate as error,
	// NOT be treated as "session not found". "Permission denied" is a real
	// transport error, unlike "No such file or directory" which just means
	// no tmux server exists yet (benign).
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-501/default (Permission denied)"}
	})
	c := NewClient(m)

	_, err := c.HasSession(t.Context(), "qm-x")
	if err == nil {
		t.Fatal("expected error for connection failure, got nil")
	}
}

func TestSessionName_ReadsTheCallersPane(t *testing.T) {
	setCaller(t, "/tmp/qm-test/sock", "%77")
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "display-message" || flagVal(args, "-t") != "%77" {
			t.Fatalf("unexpected args: %v", args)
		}
		return "/tmp/qm-test/sock\t%77\tqm-worker", nil
	})
	c := NewClient(m)

	name, err := c.SessionName(t.Context())
	if err != nil {
		t.Fatalf("SessionName: %v", err)
	}
	if name != "qm-worker" {
		t.Fatalf("got %q, want %q", name, "qm-worker")
	}
}

// TMUX_PANE names a pane on the caller's own server. On another server the
// same ID is someone else's pane, so SessionName must not answer with it.
func TestSessionName_RejectsTheCallersPaneWhenOnAnotherServer(t *testing.T) {
	tests := []struct {
		name   string
		tmux   string
		pane   string
		output string
	}{
		{name: "TMUX names another server", tmux: "/tmp/qm-test/other", pane: "%77", output: "/tmp/qm-test/sock\t%77\tqm-worker"},
		{name: "pane is not on this server", tmux: "/tmp/qm-test/sock", pane: "%77", output: "/tmp/qm-test/sock\t\t"},
		{name: "outside tmux", tmux: "", pane: "", output: ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			setCaller(t, tt.tmux, tt.pane)
			m := newMock(func(context.Context, ...string) (string, error) { return tt.output, nil })

			if name, err := NewClient(m).SessionName(t.Context()); err == nil {
				t.Fatalf("SessionName = %q, want an error", name)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// EnsureSessionRunning
// ---------------------------------------------------------------------------

func TestEnsureSessionRunning_Alive(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", nil // session exists
	})
	c := NewClient(m)

	if err := c.EnsureSessionRunning(t.Context(), "qm-abc", "worker"); err != nil {
		t.Fatalf("expected nil for alive session, got: %v", err)
	}
}

func TestEnsureSessionRunning_NotAlive_WithLabel(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	err := c.EnsureSessionRunning(t.Context(), "qm-gone", "worker")
	if err == nil {
		t.Fatal("expected error for dead session")
	}
	if !strings.Contains(err.Error(), "worker") {
		t.Errorf("expected label in error, got: %v", err)
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Errorf("expected 'not running' in error, got: %v", err)
	}
}

func TestEnsureSessionRunning_RunnerError_WithLabel(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("connection refused")
	})
	c := NewClient(m)

	err := c.EnsureSessionRunning(t.Context(), "qm-x", "master")
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "master") {
		t.Errorf("expected label in runner error, got: %v", err)
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

	if err := c.KillSession(t.Context(), "qm-abc"); err != nil {
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
	if err := c.KillSession(t.Context(), "qm-gone"); err != nil {
		t.Fatalf("KillSession of absent session: %v", err)
	}
}

func TestKillSession_ConnectionError(t *testing.T) {
	t.Parallel()

	// Transport error (permission denied) should propagate, NOT be
	// treated as "session doesn't exist" — the session may still be alive.
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-501/default (Permission denied)"}
	})
	c := NewClient(m)

	if err := c.KillSession(t.Context(), "qm-perm"); err == nil {
		t.Fatal("expected error for connection failure, got nil")
	}
}

func TestKillSession_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("server crashed")
	})
	c := NewClient(m)

	if err := c.KillSession(t.Context(), "qm-x"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// NewSession
// ---------------------------------------------------------------------------

func TestNewSession_Success(t *testing.T) {
	t.Setenv("TMUX_PANE", "")

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "new-session" {
			t.Errorf("expected new-session, got %s", args[0])
		}
		joined := strings.Join(args, " ")
		if !strings.Contains(joined, "-d") || !strings.Contains(joined, "-s") {
			t.Errorf("missing expected flags: %v", args)
		}
		if flagVal(args, "-s") != "qm-new" {
			t.Errorf("session name: got %q", flagVal(args, "-s"))
		}
		if flagVal(args, "-n") != "work" {
			t.Errorf("window name: got %q", flagVal(args, "-n"))
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "qm-new", "work", "/tmp"); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
}

func TestNewSession_OmitsBlankWindowName(t *testing.T) {
	t.Setenv("TMUX_PANE", "")

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "new-session" {
			t.Errorf("expected new-session, got %s", args[0])
		}
		if got := flagVal(args, "-n"); got != "" {
			t.Errorf("window name flag: got %q, want omitted", got)
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "qm-new", "", "/tmp"); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
}

// A new session takes the size of the client showing the caller's session, as
// tmux would pick it from the caller's pane: the most recently active one.
func TestNewSession_UsesTheCallersClientSize(t *testing.T) {
	setCaller(t, "/tmp/qm-test/sock", "%42")

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "display-message":
			if flagVal(args, "-t") != "%42" {
				t.Fatalf("expected caller pane target in args, got %v", args)
			}
			return "/tmp/qm-test/sock\t%42\tqm-master", nil
		case "list-clients":
			if flagVal(args, "-t") != "=qm-master:" {
				t.Fatalf("expected the caller's session in args, got %v", args)
			}
			return "100\tclient-old\t80\t24\n200\tclient-new\t355\t62", nil
		case "new-session":
			if flagVal(args, "-x") != "355" || flagVal(args, "-y") != "62" {
				t.Fatalf("expected client size flags in %v", args)
			}
			return "", nil
		default:
			t.Fatalf("unexpected args: %v", args)
			return "", nil
		}
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "qm-sized", "work", "/tmp"); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
}

func TestNewSession_IgnoresAPaneOnAnotherServer(t *testing.T) {
	setCaller(t, "/tmp/qm-test/other", "%42")

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "display-message":
			return "/tmp/qm-test/sock\t%42\tqm-unrelated", nil
		case "new-session":
			if flagVal(args, "-x") != "" || flagVal(args, "-y") != "" {
				t.Fatalf("sized from another server's pane: %v", args)
			}
			return "", nil
		default:
			t.Fatalf("unexpected args: %v", args)
			return "", nil
		}
	})

	if err := NewClient(m).NewSession(t.Context(), "qm-unsized", "work", "/tmp"); err != nil {
		t.Fatalf("NewSession: %v", err)
	}
}

func TestNewSession_Error(t *testing.T) {
	t.Setenv("TMUX_PANE", "")

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("duplicate session")
	})
	c := NewClient(m)

	if err := c.NewSession(t.Context(), "qm-dup", "work", "/tmp"); err == nil {
		t.Fatal("expected error, got nil")
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

	if err := c.RespawnPane(t.Context(), "qm-s:0.0", "/tmp", "bash"); err != nil {
		t.Fatalf("RespawnPane: %v", err)
	}
}

func TestRespawnPaneChangesIntoTheDirectoryBeforeTheCommand(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		cwd  string
		cmd  string
		want string
	}{
		{name: "plain directory", cwd: "/work/repo", cmd: "exec claude", want: "cd -- '/work/repo' || exit 1; exec claude"},
		{name: "quote in directory", cwd: "/work/it's", cmd: "exec zsh -l", want: `cd -- '/work/it'"'"'s' || exit 1; exec zsh -l`},
		{name: "no directory", cwd: "", cmd: "exec claude", want: "exec claude"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var got []string
			c := NewClient(newMock(func(_ context.Context, args ...string) (string, error) {
				got = args
				return "", nil
			}))
			if err := c.RespawnPane(t.Context(), "qm-s:0.0", tt.cwd, tt.cmd); err != nil {
				t.Fatalf("RespawnPane: %v", err)
			}
			if command := got[len(got)-1]; command != tt.want {
				t.Fatalf("command = %q, want %q", command, tt.want)
			}
		})
	}
}

func TestRespawnPane_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane dead")
	})
	c := NewClient(m)

	if err := c.RespawnPane(t.Context(), "qm-s:0.0", "/tmp", "bash"); err == nil {
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

	if err := c.SplitWindow(t.Context(), "qm-s:0.0", "/tmp", "bash", true); err != nil {
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

	if err := c.SplitWindow(t.Context(), "qm-s:0.0", "/tmp", "bash", false); err != nil {
		t.Fatalf("SplitWindow: %v", err)
	}
}

func TestSplitWindow_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("no space")
	})
	c := NewClient(m)

	if err := c.SplitWindow(t.Context(), "qm-s:0.0", "/tmp", "bash", true); err == nil {
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

	if err := c.NewWindow(t.Context(), "qm-s", "work", "/tmp"); err != nil {
		t.Fatalf("NewWindow: %v", err)
	}
}

func TestNewWindow_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("session gone")
	})
	c := NewClient(m)

	if err := c.NewWindow(t.Context(), "qm-s", "work", "/tmp"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// KillWindow
// ---------------------------------------------------------------------------

func TestKillWindow_Success(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "kill-window" {
			t.Errorf("expected kill-window, got %s", args[0])
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.KillWindow(t.Context(), "qm-s:0"); err != nil {
		t.Fatalf("KillWindow: %v", err)
	}
}

func TestKillWindow_NotFound(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	// Should return nil when window doesn't exist
	if err := c.KillWindow(t.Context(), "qm-gone:0"); err != nil {
		t.Fatalf("KillWindow of absent window: %v", err)
	}
}

func TestKillWindow_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("server crashed")
	})
	c := NewClient(m)

	if err := c.KillWindow(t.Context(), "qm-x:0"); err == nil {
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

	if err := c.RenameWindow(t.Context(), "qm-s:0", "codex"); err != nil {
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

	if err := c.SelectPane(t.Context(), "qm-s:0.1"); err != nil {
		t.Fatalf("SelectPane: %v", err)
	}
}

func TestSelectPane_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("pane not found")
	})
	c := NewClient(m)

	if err := c.SelectPane(t.Context(), "qm-s:0.9"); err == nil {
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
		if flagVal(args, "-T") != "Claude" {
			t.Errorf("title: got %q", flagVal(args, "-T"))
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SelectPaneTitle(t.Context(), "qm-s:0.1", "Claude"); err != nil {
		t.Fatalf("SelectPaneTitle: %v", err)
	}
}

func TestSetManagedPaneTitleKeepsBorderTitleAfterNativeUpdate(t *testing.T) {
	const original = "#{?pane_active,#[fg=green] #{pane_title},#{pane_title}}"
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return original, nil
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.SetManagedPaneTitle(t.Context(), "qm-s:0.1", "Fix #123"); err != nil {
		t.Fatalf("SetManagedPaneTitle: %v", err)
	}

	var paneOption, borderFormat string
	for _, call := range m.calls {
		args := call.args
		if len(args) < 6 || args[0] != "set-option" {
			continue
		}
		switch args[1] {
		case "-p":
			if args[3] != "qm-s:0.1" {
				t.Fatalf("pane option call = %v", args)
			}
			switch args[4] {
			case "@questmaster_title":
				paneOption = args[5]
			case "pane-border-format":
				borderFormat = args[5]
			default:
				t.Fatalf("pane option call = %v", args)
			}
		}
	}
	if paneOption != "Fix #123" {
		t.Fatalf("pane title option = %q", paneOption)
	}
	if borderFormat != "#{?pane_active,#[fg=green] #{?#{==:#{@questmaster_title},},#{pane_title},#{@questmaster_title}},#{?#{==:#{@questmaster_title},},#{pane_title},#{@questmaster_title}}}" {
		t.Fatalf("border format = %q", borderFormat)
	}
}

func TestSetManagedPaneTitlePreservesOtherPanesWithoutTitles(t *testing.T) {
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "display-message" {
			return "#{pane_index}", nil
		}
		return "", nil
	})
	c := NewClient(m)
	if err := c.SetManagedPaneTitle(t.Context(), "qm-s:0.1", "Agent title"); err != nil {
		t.Fatal(err)
	}
	for _, call := range m.calls {
		args := call.args
		if len(args) == 6 && args[0] == "set-option" && args[1] == "-p" && args[4] == "pane-border-format" {
			if args[5] != "#{pane_index}#{?#{==:#{@questmaster_title},},, #{@questmaster_title}}" {
				t.Fatalf("border format = %q", args[5])
			}
			return
		}
	}
	t.Fatal("pane border format was not set")
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

	if err := c.SelectWindow(t.Context(), "qm-s:1"); err != nil {
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

	if err := c.SetPaneOption(t.Context(), "qm-s:0.0", "@party_role", "codex"); err != nil {
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

	if err := c.SetWindowOption(t.Context(), "qm-s:0", "pane-border-status", "top"); err != nil {
		t.Fatalf("SetWindowOption: %v", err)
	}
}

func TestSetPaneOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetPaneOption(t.Context(), "qm-s:0.0", "bad", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSetWindowOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetWindowOption(t.Context(), "qm-s:0", "bad", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

func TestSetSessionOption_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad option")
	})
	c := NewClient(m)

	if err := c.SetSessionOption(t.Context(), "qm-s", "bad", "val"); err == nil {
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

	if err := c.SetEnvironment(t.Context(), "qm-s", "KEY", "val"); err != nil {
		t.Fatalf("SetEnvironment: %v", err)
	}
}

func TestSetEnvironment_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("session gone")
	})
	c := NewClient(m)

	if err := c.SetEnvironment(t.Context(), "qm-s", "KEY", "val"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// UnsetEnvironment
// ---------------------------------------------------------------------------

func TestUnsetEnvironment_Session(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if got := strings.Join(args, " "); got != "set-environment -t =qm-s: -u KEY" {
			t.Errorf("args = %q, want a session-scoped unset", got)
		}
		return "", nil
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "qm-s", "KEY"); err != nil {
		t.Fatalf("UnsetEnvironment: %v", err)
	}
}

func TestUnsetEnvironment_NotSet(t *testing.T) {
	t.Parallel()

	// Non-zero exit (var not set) → nil error
	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", &ExitError{Code: 1}
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "qm-s", "MISSING"); err != nil {
		t.Fatalf("expected nil for absent var, got: %v", err)
	}
}

func TestUnsetEnvironment_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("server crashed")
	})
	c := NewClient(m)

	if err := c.UnsetEnvironment(t.Context(), "qm-s", "KEY"); err == nil {
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

	val, ok, err := c.ShowEnvironment(t.Context(), "qm-s", "MY_KEY")
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

	_, ok, err := c.ShowEnvironment(t.Context(), "qm-s", "MISSING")
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

	_, ok, err := c.ShowEnvironment(t.Context(), "qm-s", "MY_KEY")
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

	val, ok, err := c.ShowEnvironment(t.Context(), "qm-s", "WEIRDFORMAT")
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

	_, _, err := c.ShowEnvironment(t.Context(), "qm-s", "KEY")
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

	if err := c.SetHook(t.Context(), "qm-s", "session-closed", "run-shell 'cleanup'"); err != nil {
		t.Fatalf("SetHook: %v", err)
	}
}

func TestSetHook_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("bad hook")
	})
	c := NewClient(m)

	if err := c.SetHook(t.Context(), "qm-s", "bad", "cmd"); err == nil {
		t.Fatal("expected error, got nil")
	}
}

// ---------------------------------------------------------------------------
// SwitchClient
// ---------------------------------------------------------------------------

func TestSwitchClient_MovesTheCallersMostRecentClient(t *testing.T) {
	setCaller(t, "/tmp/qm-test/sock", "%3")

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "display-message":
			return "/tmp/qm-test/sock\t%3\tqm-master", nil
		case "list-clients":
			return "300\tclient-new\t200\t50\n100\tclient-old\t80\t24", nil
		case "switch-client":
			if flagVal(args, "-c") != "client-new" || flagVal(args, "-t") != "=qm-new:" {
				t.Errorf("switch-client args = %v, want -c client-new -t =qm-new:", args)
			}
			return "", nil
		default:
			t.Fatalf("unexpected args: %v", args)
			return "", nil
		}
	})

	if err := NewClient(m).SwitchClient(t.Context(), "qm-new"); err != nil {
		t.Fatalf("SwitchClient: %v", err)
	}
	if last := m.calls[len(m.calls)-1].args; last[0] != "switch-client" {
		t.Fatalf("last call = %v, want switch-client", last)
	}
}

// Without a client tied to the caller's own pane there is nothing to switch.
// Picking another client would move a terminal the caller is not using.
func TestSwitchClient_NeverGuessesAClient(t *testing.T) {
	tests := []struct {
		name    string
		tmux    string
		display string
		clients string
	}{
		{name: "caller on another server", tmux: "/tmp/qm-test/other", display: "/tmp/qm-test/sock\t%3\tqm-master", clients: "1\tclient-a\t80\t24"},
		{name: "caller session has no client", tmux: "/tmp/qm-test/sock", display: "/tmp/qm-test/sock\t%3\tqm-master", clients: ""},
		{name: "outside tmux", tmux: "", display: "", clients: "1\tclient-a\t80\t24"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pane := "%3"
			if tt.tmux == "" {
				pane = ""
			}
			setCaller(t, tt.tmux, pane)
			m := newMock(func(_ context.Context, args ...string) (string, error) {
				switch args[0] {
				case "display-message":
					return tt.display, nil
				case "list-clients":
					return tt.clients, nil
				}
				t.Fatalf("unexpected call: %v", args)
				return "", nil
			})

			if err := NewClient(m).SwitchClient(t.Context(), "qm-new"); err == nil {
				t.Fatal("SwitchClient succeeded, want an error")
			}
		})
	}
}

func TestSwitchClient_PropagatesTransportErrors(t *testing.T) {
	setCaller(t, "/tmp/qm-test/sock", "%3")
	m := newMock(func(_ context.Context, args ...string) (string, error) {
		if args[0] == "switch-client" {
			t.Fatalf("switched after a failed lookup: %v", args)
		}
		return "", errors.New("connection refused")
	})

	if err := NewClient(m).SwitchClient(t.Context(), "qm-x"); err == nil {
		t.Fatal("expected error propagation")
	}
}

// setCaller sets the TMUX and TMUX_PANE a process inside a tmux pane would
// inherit. An empty socket clears both.
func setCaller(t *testing.T, socket, pane string) {
	t.Helper()
	tmuxValue := ""
	if socket != "" {
		tmuxValue = socket + ",4242,0"
	}
	t.Setenv("TMUX", tmuxValue)
	t.Setenv("TMUX_PANE", pane)
}

// ---------------------------------------------------------------------------
// RunBatch
// ---------------------------------------------------------------------------

func TestRunBatch_Empty(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		t.Fatal("should not be called for empty batch")
		return "", nil
	})
	c := NewClient(m)

	out, err := c.RunBatch(t.Context())
	if err != nil {
		t.Fatalf("RunBatch empty: %v", err)
	}
	if out != "" {
		t.Errorf("output: got %q, want empty", out)
	}
}

func TestRunBatch_SingleCommand(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		// Single command — no separator expected.
		if len(args) != 4 {
			t.Errorf("args len: got %d, want 4: %v", len(args), args)
		}
		return "", nil
	})
	c := NewClient(m)

	_, err := c.RunBatch(t.Context(),
		[]string{"set-option", "-p", "-t", "s:0.0"},
	)
	if err != nil {
		t.Fatalf("RunBatch single: %v", err)
	}
	if len(m.calls) != 1 {
		t.Errorf("call count: got %d, want 1", len(m.calls))
	}
}

func TestRunBatch_MultipleCommands(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		return "", nil
	})
	c := NewClient(m)

	_, err := c.RunBatch(t.Context(),
		[]string{"set-option", "-p", "-t", "s:0.0", "@role", "codex"},
		[]string{"set-option", "-p", "-t", "s:0.1", "@role", "claude"},
	)
	if err != nil {
		t.Fatalf("RunBatch multi: %v", err)
	}
	// Commands are executed sequentially — one Run call per command.
	if len(m.calls) != 2 {
		t.Errorf("call count: got %d, want 2 (sequential)", len(m.calls))
	}
}

func TestRunBatch_Error(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, _ ...string) (string, error) {
		return "", errors.New("batch failed")
	})
	c := NewClient(m)

	_, err := c.RunBatch(t.Context(),
		[]string{"set-option", "-p", "-t", "s:0.0", "key", "val"},
		[]string{"select-pane", "-t", "s:0.1"},
	)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
}

// W5: RunBatch should execute commands individually and stop on first error.
// Currently all commands are batched into a single tmux invocation, so an early
// failure doesn't prevent later commands from executing (corrupting pane topology).
func TestRunBatch_StopsOnFirstError(t *testing.T) {
	t.Parallel()

	m := newMock(func(_ context.Context, args ...string) (string, error) {
		// Fail on select-pane commands
		if args[0] == "select-pane" {
			return "", errors.New("pane not found")
		}
		return "", nil
	})
	c := NewClient(m)

	_, err := c.RunBatch(t.Context(),
		[]string{"set-option", "-p", "-t", "s:0.0", "key", "val"},
		[]string{"select-pane", "-t", "s:0.1"},
		[]string{"set-option", "-p", "-t", "s:0.2", "key", "val"},
	)
	if err == nil {
		t.Fatal("expected error from failing command, got nil")
	}
	// After fix: commands execute individually; third command should not run.
	// Currently: all batched into one Run call (len(m.calls)==1).
	if len(m.calls) != 2 {
		t.Errorf("expected 2 calls (stop after second fails), got %d", len(m.calls))
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
