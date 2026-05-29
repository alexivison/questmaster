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
		"-w", "40%",
		"-h", "60%",
		"-e", "QUESTMASTER_PICKER_POPUP=1",
		"-e", "QUESTMASTER_STATE_ROOT=/state root",
		"-e", "PARTY_REPO_ROOT=/repo root",
		"/Applications/Questmaster/bin/questmaster",
		"picker",
	}
	if !reflect.DeepEqual(plan.Args, want) {
		t.Fatalf("popup args mismatch\ngot:  %#v\nwant: %#v", plan.Args, want)
	}
	if joined := strings.Join(plan.Args, "\x00"); strings.Contains(joined, "preview") {
		t.Fatalf("popup command should not reintroduce preview: %v", plan.Args)
	}
}

func TestPickerPopupPlanUsesTmuxEnvOptionsInsteadOfShellEnvCommand(t *testing.T) {
	t.Parallel()

	plan, err := buildPickerPopupPlan(pickerPopupPlanInput{
		TMUX:       "/tmp/tmux-501/default,123,0",
		PopupEnv:   "",
		Target:     "%42",
		Executable: "/tmp/questmaster's/bin/questmaster",
		RepoRoot:   "/repo root/with spaces",
		StateRoot:  "/state root/with spaces",
	})
	if err != nil {
		t.Fatalf("build popup plan: %v", err)
	}
	if !plan.Launch {
		t.Fatal("inside tmux should launch a popup")
	}

	for _, arg := range plan.Args {
		if strings.HasPrefix(arg, "env ") {
			t.Fatalf("popup args should not wrap the child in a shell env command: %v", plan.Args)
		}
	}

	wantSuffix := []string{
		"-e", "QUESTMASTER_PICKER_POPUP=1",
		"-e", "QUESTMASTER_STATE_ROOT=/state root/with spaces",
		"-e", "PARTY_REPO_ROOT=/repo root/with spaces",
		"/tmp/questmaster's/bin/questmaster",
		"picker",
	}
	gotSuffix := plan.Args[len(plan.Args)-len(wantSuffix):]
	if !reflect.DeepEqual(gotSuffix, wantSuffix) {
		t.Fatalf("popup env/command args mismatch\ngot:  %#v\nwant: %#v", gotSuffix, wantSuffix)
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
