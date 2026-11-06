package tmuxconfig_test

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

type statusRunner struct {
	started int64
	marker  string
	calls   [][]string
	absent  bool
}

func (r *statusRunner) Run(_ context.Context, args ...string) (string, error) {
	r.calls = append(r.calls, append([]string(nil), args...))
	switch strings.Join(args, " ") {
	case "display-message -p -F #{start_time}|#{server_sessions}":
		if r.absent {
			return "", &tmux.ExitError{Code: 1, Stderr: "no server running on private socket"}
		}
		return strconv.FormatInt(r.started, 10) + "|2", nil
	case "show-options -gqv @questmaster_enforced":
		return r.marker, nil
	default:
		panic("unexpected tmux command: " + strings.Join(args, " "))
	}
}

func TestStatusEditedSinceStart(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	if err := prepareConfig(t, root); err != nil {
		t.Fatal(err)
	}
	start := time.Now().Truncate(time.Second)
	path := tmuxconfig.Paths(root).Config
	if err := os.Chtimes(path, start.Add(-time.Minute), start.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	r := &statusRunner{started: start.Unix(), marker: "1"}
	status, err := tmuxconfig.Status(t.Context(), tmux.NewClient(r), root)
	if err != nil || status.EditedSinceStart || !status.Running || status.StartedUnix != start.Unix() || status.Sessions != 2 {
		t.Fatalf("before edit: %+v, %v", status, err)
	}
	if err := os.Chtimes(path, start.Add(time.Minute), start.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	status, err = tmuxconfig.Status(t.Context(), tmux.NewClient(r), root)
	if err != nil || !status.EditedSinceStart || status.TemplateVersion != 3 || status.BuiltinTemplateVersion != 3 {
		t.Fatalf("after edit: %+v, %v", status, err)
	}
}

func TestStatusEnforcedPending(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	r := &statusRunner{started: time.Now().Unix(), marker: "0"}
	status, err := tmuxconfig.Status(t.Context(), tmux.NewClient(r), root)
	if err != nil || !status.EnforcedPending {
		t.Fatalf("old marker: %+v, %v", status, err)
	}
	r.marker = "1"
	status, err = tmuxconfig.Status(t.Context(), tmux.NewClient(r), root)
	if err != nil || status.EnforcedPending {
		t.Fatalf("current marker: %+v, %v", status, err)
	}
}

func TestStatusNotRunningStartsNothing(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	r := &statusRunner{absent: true}
	status, err := tmuxconfig.Status(t.Context(), tmux.NewClient(r), root)
	if err != nil || status.Running || status.StartedUnix != 0 || status.Sessions != 0 || status.EnforcedPending {
		t.Fatalf("absent: %+v, %v", status, err)
	}
	if len(r.calls) != 1 || r.calls[0][0] != "display-message" {
		t.Fatalf("unexpected tmux calls: %v", r.calls)
	}
	if _, err := os.Stat(filepath.Join(root, "tmux")); !os.IsNotExist(err) {
		t.Fatalf("status wrote files: %v", err)
	}
}
