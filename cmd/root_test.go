package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func TestRootNoArgs_ReachesTUI(t *testing.T) {
	t.Parallel()

	var tuiCalled bool
	root := NewRootCmd(WithTUILauncher(func() error {
		tuiCalled = true
		return nil
	}))
	root.SetArgs([]string{})
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err != nil {
		t.Fatalf("root execute: %v", err)
	}

	if !tuiCalled {
		t.Fatal("expected TUI launcher to be called with no args")
	}
}

func TestSubcommand_DoesNotLaunchTUI(t *testing.T) {
	t.Parallel()

	var tuiCalled bool
	root := NewRootCmd(WithTUILauncher(func() error {
		tuiCalled = true
		return nil
	}))
	root.SetArgs([]string{"version"})
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err != nil {
		t.Fatalf("version execute: %v", err)
	}

	if tuiCalled {
		t.Fatal("TUI launcher should not be called for subcommands")
	}
}

func TestExecuteHookUsesFastPath(t *testing.T) {
	t.Parallel()

	var fullCalled bool
	var hookCalled bool
	var errOut bytes.Buffer

	err := executeWithArgs(
		[]string{"hook", "--session", "../bad", "claude", "starting"},
		bytes.NewReader(nil),
		&bytes.Buffer{},
		&errOut,
		func() *cobra.Command {
			fullCalled = true
			return &cobra.Command{Use: "questmaster"}
		},
		func() *cobra.Command {
			hookCalled = true
			root := &cobra.Command{Use: "questmaster"}
			root.AddCommand(&cobra.Command{
				Use: "hook",
				RunE: func(cmd *cobra.Command, _ []string) error {
					_, _ = cmd.OutOrStdout().Write([]byte("hook fast path\n"))
					return nil
				},
			})
			return root
		},
	)
	if err != nil {
		t.Fatalf("execute hook fast path: %v", err)
	}
	if fullCalled {
		t.Fatal("hook invocation constructed the full root command")
	}
	if hookCalled {
		t.Fatal("valid hook invocation fell back to the hook Cobra root")
	}
	if !strings.Contains(errOut.String(), "invalid QUESTMASTER_SESSION") {
		t.Fatalf("stderr: got %q", errOut.String())
	}
}

func TestHookFastPathInvalidSessionMatchesHookCommand(t *testing.T) {
	t.Parallel()

	args := []string{"--session", "../bad", "claude", "starting"}

	var fastErr bytes.Buffer
	handled, err := executeHookFastPath(args, bytes.NewReader(nil), &fastErr)
	if err != nil {
		t.Fatalf("fast path: %v", err)
	}
	if !handled {
		t.Fatal("fast path did not handle valid hook shape")
	}

	root := newHookRootCmd()
	var cobraErr bytes.Buffer
	root.SetArgs(append([]string{"hook"}, args...))
	root.SetIn(bytes.NewReader(nil))
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&cobraErr)
	if err := root.Execute(); err != nil {
		t.Fatalf("hook command: %v", err)
	}

	if fastErr.String() != cobraErr.String() {
		t.Fatalf("stderr differs\nfast: %q\ncobra: %q", fastErr.String(), cobraErr.String())
	}
}

func TestHookFastPathHelpMatchesFullCommand(t *testing.T) {
	t.Parallel()

	full := NewRootCmd(WithTUILauncher(func() error { return nil }))
	fast := newHookRootCmd()

	var fullOut bytes.Buffer
	full.SetArgs([]string{"hook", "--help"})
	full.SetOut(&fullOut)
	full.SetErr(&bytes.Buffer{})
	if err := full.Execute(); err != nil {
		t.Fatalf("full hook help: %v", err)
	}

	var fastOut bytes.Buffer
	fast.SetArgs([]string{"hook", "--help"})
	fast.SetOut(&fastOut)
	fast.SetErr(&bytes.Buffer{})
	if err := fast.Execute(); err != nil {
		t.Fatalf("fast hook help: %v", err)
	}

	if fullOut.String() != fastOut.String() {
		t.Fatalf("hook help differs\nfull:\n%s\nfast:\n%s", fullOut.String(), fastOut.String())
	}
}

func TestHelpSubcommand_Runs(t *testing.T) {
	t.Parallel()

	root := NewRootCmd()
	var out bytes.Buffer
	root.SetArgs([]string{"help"})
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err != nil {
		t.Fatalf("help execute: %v", err)
	}

	if out.Len() == 0 {
		t.Fatal("expected help output")
	}
	if bytes.Contains(out.Bytes(), []byte("\n  config")) {
		t.Fatalf("help should not show config command, got:\n%s", out.String())
	}
}

func TestConfigSubcommandRemoved(t *testing.T) {
	t.Parallel()

	root := NewRootCmd(WithTUILauncher(func() error { return nil }))
	root.SetArgs([]string{"config", "init"})
	root.SetOut(&bytes.Buffer{})
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err == nil {
		t.Fatal("expected config subcommand to be unknown")
	}
}

func TestVersionSubcommand_PrintsVersion(t *testing.T) {
	t.Parallel()

	root := NewRootCmd()
	var out bytes.Buffer
	root.SetArgs([]string{"version"})
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err != nil {
		t.Fatalf("version execute: %v", err)
	}

	if !bytes.Contains(out.Bytes(), []byte("questmaster")) {
		t.Fatalf("expected version output to contain 'questmaster', got: %s", out.String())
	}
}

func TestDeprecatedLayoutFlagAccepted(t *testing.T) {
	t.Parallel()

	startCmd := newStartCmd(nil, nil, "")
	spawnCmd := newSpawnCmd(nil, nil, "")

	for _, cmd := range []struct {
		name    string
		command interface{ Flags() *pflag.FlagSet }
	}{
		{"start", startCmd},
		{"spawn", spawnCmd},
	} {
		flag := cmd.command.Flags().Lookup("layout")
		if flag == nil {
			t.Errorf("%s: --layout flag should remain registered as deprecated", cmd.name)
			continue
		}
		if !flag.Hidden {
			t.Errorf("%s: --layout should be hidden", cmd.name)
		}
		if flag.Deprecated == "" {
			t.Errorf("%s: --layout should carry a deprecation message", cmd.name)
		}
	}
}
