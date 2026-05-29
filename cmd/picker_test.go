package cmd

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

func TestPickerPopupPlanOutsideTmuxRunsInline(t *testing.T) {
	t.Parallel()

	plan, err := buildPickerPopupPlan(pickerPopupPlanInput{
		TMUX:       "",
		PopupEnv:   "",
		Target:     "%1",
		Executable: "/usr/local/bin/questmaster",
		RepoRoot:   "/repo",
		StateRoot:  "/state",
	})
	if err != nil {
		t.Fatalf("build popup plan: %v", err)
	}
	if plan.Launch {
		t.Fatalf("outside tmux should run inline, got popup args %v", plan.Args)
	}
}

func TestPickerPopupPlanInsideTmuxUsesNarrowAutoClosingPopup(t *testing.T) {
	t.Parallel()

	plan, err := buildPickerPopupPlan(pickerPopupPlanInput{
		TMUX:       "/tmp/tmux-501/default,123,0",
		PopupEnv:   "",
		Target:     "%42",
		Executable: "/Applications/Questmaster/bin/questmaster",
		RepoRoot:   "/repo root",
		StateRoot:  "/state root",
	})
	if err != nil {
		t.Fatalf("build popup plan: %v", err)
	}
	if !plan.Launch {
		t.Fatal("inside tmux should launch a popup")
	}

	want := []string{
		"display-popup", "-E",
		"-t", "%42",
		"-w", "60%",
		"-h", "80%",
		"env QUESTMASTER_PICKER_POPUP=1 QUESTMASTER_STATE_ROOT='/state root' PARTY_REPO_ROOT='/repo root' '/Applications/Questmaster/bin/questmaster' picker",
	}
	if !reflect.DeepEqual(plan.Args, want) {
		t.Fatalf("popup args mismatch\ngot:  %#v\nwant: %#v", plan.Args, want)
	}
	if strings.Contains(plan.Args[len(plan.Args)-1], "preview") {
		t.Fatalf("popup command should not reintroduce preview: %s", plan.Args[len(plan.Args)-1])
	}
}

func TestPickerPopupPlanMarkedPopupRunsInline(t *testing.T) {
	t.Parallel()

	plan, err := buildPickerPopupPlan(pickerPopupPlanInput{
		TMUX:       "/tmp/tmux-501/default,123,0",
		PopupEnv:   "1",
		Target:     "%42",
		Executable: "/usr/local/bin/questmaster",
		RepoRoot:   "/repo",
		StateRoot:  "/state",
	})
	if err != nil {
		t.Fatalf("build popup plan: %v", err)
	}
	if plan.Launch {
		t.Fatalf("popup child should run inline, got popup args %v", plan.Args)
	}
}

func TestRunPickerInsideTmuxLaunchesPopupAndReturns(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-501/default,123,0")
	t.Setenv("TMUX_PANE", "%42")
	t.Setenv(pickerPopupEnv, "")

	store := setupStore(t)
	var calls [][]string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		calls = append(calls, append([]string(nil), args...))
		return "", nil
	}}
	client := tmux.NewClient(runner)
	cmd := &cobra.Command{}

	if err := runPicker(cmd, store, client, "/repo"); err != nil {
		t.Fatalf("run picker: %v", err)
	}
	if len(calls) != 1 {
		t.Fatalf("tmux calls = %v, want exactly one popup call", calls)
	}
	if calls[0][0] != "display-popup" {
		t.Fatalf("tmux call = %v, want display-popup", calls[0])
	}
	if !containsArg(calls[0], "-E") {
		t.Fatalf("popup args should auto-close with -E, got %v", calls[0])
	}
}

func containsArg(args []string, want string) bool {
	for _, arg := range args {
		if arg == want {
			return true
		}
	}
	return false
}
