package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func TestRootNoArgs_ShowsHelp(t *testing.T) {
	t.Parallel()

	root := NewRootCmd()
	var out bytes.Buffer
	root.SetArgs([]string{})
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})

	if err := root.Execute(); err != nil {
		t.Fatalf("root execute: %v", err)
	}

	if !strings.Contains(out.String(), "Usage:") {
		t.Fatalf("expected no-args help output, got:\n%s", out.String())
	}
}

func TestRemovedTUICommandsAreUnknown(t *testing.T) {
	t.Parallel()

	for _, args := range [][]string{
		{"picker"},
		{"resize", "qm-r"},
		{"quest", "board"},
	} {
		root := NewRootCmd()
		root.SetArgs(args)
		root.SetOut(&bytes.Buffer{})
		root.SetErr(&bytes.Buffer{})
		if err := root.Execute(); err == nil {
			t.Fatalf("expected %v to be unknown", args)
		}
	}
}

func TestExecuteHookUsesFastPath(t *testing.T) {
	t.Parallel()

	var fullCalled bool
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
	)
	if err != nil {
		t.Fatalf("execute hook fast path: %v", err)
	}
	if fullCalled {
		t.Fatal("hook invocation constructed the full root command")
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

	root := NewRootCmd()
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

func TestHookHelpFallsBackToRootCommand(t *testing.T) {
	t.Parallel()

	var rootCalled bool
	root := NewRootCmd()

	var want bytes.Buffer
	root.SetArgs([]string{"hook", "--help"})
	root.SetOut(&want)
	root.SetErr(&bytes.Buffer{})
	if err := root.Execute(); err != nil {
		t.Fatalf("full hook help: %v", err)
	}

	var got bytes.Buffer
	err := executeWithArgs(
		[]string{"hook", "--help"},
		bytes.NewReader(nil),
		&got,
		&bytes.Buffer{},
		func() *cobra.Command {
			rootCalled = true
			return NewRootCmd()
		},
	)
	if err != nil {
		t.Fatalf("execute hook help: %v", err)
	}
	if !rootCalled {
		t.Fatal("hook help should fall back to the root command")
	}
	if want.String() != got.String() {
		t.Fatalf("hook help differs\nwant:\n%s\ngot:\n%s", want.String(), got.String())
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

	root := NewRootCmd()
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
