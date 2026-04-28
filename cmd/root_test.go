package cmd

import (
	"bytes"
	"testing"

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

	if !bytes.Contains(out.Bytes(), []byte("party-cli")) {
		t.Fatalf("expected version output to contain 'party-cli', got: %s", out.String())
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
