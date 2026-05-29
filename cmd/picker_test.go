package cmd

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func TestRunPickerInsideTmuxRunsInline(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-501/default,123,0")
	t.Setenv("TMUX_PANE", "%42")

	origRunPickerProgram := runPickerProgram
	t.Cleanup(func() { runPickerProgram = origRunPickerProgram })

	var ranPicker bool
	runPickerProgram = func(m picker.Model) (picker.Model, error) {
		ranPicker = true
		return m, nil
	}

	store := setupStore(t)
	var calls [][]string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		calls = append(calls, append([]string(nil), args...))
		if len(args) > 0 && args[0] == "list-sessions" {
			return "", nil
		}
		return "qm-current", nil
	}}
	client := tmux.NewClient(runner)
	cmd := &cobra.Command{}

	if err := runPicker(cmd, store, client, "/repo"); err != nil {
		t.Fatalf("run picker: %v", err)
	}
	if !ranPicker {
		t.Fatal("picker should run inline instead of delegating to tmux")
	}
	for _, call := range calls {
		if len(call) > 0 && call[0] == "display-popup" {
			t.Fatalf("picker must not launch tmux display-popup, calls: %v", calls)
		}
	}
}
