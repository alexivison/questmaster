package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type configAPIRunner func(context.Context, ...string) (string, error)

func (f configAPIRunner) Run(ctx context.Context, args ...string) (string, error) {
	return f(ctx, args...)
}

func TestTmuxConfigAPICommandsUseNamedRoute(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_1")
	store := state.OpenStore(root)
	var calls []string
	client := tmux.NewClient(configAPIRunner(func(_ context.Context, args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		switch args[0] {
		case "display-message":
			return "", &tmux.ExitError{Code: 1, Stderr: "no server running on private socket"}
		case "if-shell":
			return "", &tmux.ExitError{Code: 1, Stderr: "no server running on private socket"}
		default:
			t.Fatalf("unexpected command: %v", args)
			return "", nil
		}
	}))
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_1": client}, func() string { return "default" }, nil)
	for _, args := range [][]string{{"tmux", "config", "status"}, {"tmux", "config", "reload"}, {"tmux", "restart"}} {
		cmd := NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
		var out bytes.Buffer
		cmd.SetOut(&out)
		cmd.SetArgs(args)
		if err := cmd.Execute(); err != nil {
			t.Fatalf("%v: %v", args, err)
		}
		var result map[string]any
		if err := json.Unmarshal(out.Bytes(), &result); err != nil {
			t.Fatalf("%v: invalid JSON %q: %v", args, out.String(), err)
		}
		if len(result) == 0 {
			t.Fatalf("%v: empty result", args)
		}
	}
	if len(calls) != 3 || !strings.HasPrefix(calls[2], "if-shell -F #{==:#{server_sessions},0} kill-server ") {
		t.Fatalf("tmux calls: %v", calls)
	}
	if _, err := os.Stat(filepath.Join(root, "tmux")); !os.IsNotExist(err) {
		t.Fatalf("read-only commands wrote config: %v", err)
	}
}
