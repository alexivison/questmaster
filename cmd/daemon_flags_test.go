//go:build linux || darwin

package cmd

import (
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestDaemonCutoverCommandFlags(t *testing.T) {
	t.Parallel()
	root := NewRootCmd(WithDeps(state.OpenStore(t.TempDir()), nil))
	for _, command := range root.Commands() {
		if command.Name() == "serve" {
			t.Fatal("legacy serve command remains")
		}
	}
	daemon, _, err := root.Find([]string{"daemon"})
	if err != nil {
		t.Fatal(err)
	}
	if daemon.PersistentFlags().Lookup("build-from") == nil {
		t.Fatal("dev build flag missing")
	}
	run, _, err := root.Find([]string{"daemon", "run"})
	if err != nil {
		t.Fatal(err)
	}
	if run.Flags().Lookup("clock-interval") == nil {
		t.Fatal("daemon clock interval missing")
	}
	for _, name := range []string{"socket", "interval"} {
		if run.Flags().Lookup(name) != nil {
			t.Fatalf("legacy --%s flag remains", name)
		}
	}
}
