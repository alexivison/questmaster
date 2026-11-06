package cmd

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestAttachArgv(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id := "qm-attach-route"
	if err := store.Create(state.Manifest{SessionID: id, TmuxServer: "test_named"}); err != nil {
		t.Fatal(err)
	}
	live := true
	seenSocket := "/tmp/private-other.sock"
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "has-session" {
			if live {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if args[0] == "display-message" {
			return seenSocket + "\t%1\tqm-caller", nil
		}
		return "", nil
	}}
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"default": tmux.NewClient(runner), "test_named": tmux.NewClient(runner),
	}, func() string { return "default" }, []string{"/tmp/user.conf", "/tmp/enforced.conf"})
	t.Setenv("TMUX", "")
	command, _, same, err := attachPlan(t.Context(), store, router, id)
	if err != nil || same {
		t.Fatalf("outside attach = %v, %v", same, err)
	}
	if got := strings.Join(command.Args, " "); !strings.Contains(got, "-L test_named -f /tmp/user.conf -f /tmp/enforced.conf attach-session -t =qm-attach-route:") {
		t.Fatalf("argv = %s", got)
	}
	t.Setenv("TMUX", "/tmp/private-named.sock,1,0")
	t.Setenv("TMUX_PANE", "%1")
	seenSocket = "/tmp/private-named.sock"
	command, _, same, err = attachPlan(t.Context(), store, router, id)
	if err != nil || !same || command != nil {
		t.Fatalf("same-server attach = %v, %v, %v", command, same, err)
	}
	seenSocket = "/tmp/private-other.sock"
	command, _, same, err = attachPlan(t.Context(), store, router, id)
	if err != nil || same || command == nil {
		t.Fatalf("cross-server attach = %v, %v, %v", command, same, err)
	}
	if command.Env == nil {
		t.Fatal("attach environment missing")
	}
	for _, pair := range command.Env {
		if strings.HasPrefix(pair, "TMUX=") || strings.HasPrefix(pair, "TMUX_PANE=") || strings.HasPrefix(pair, "TMUX_TMPDIR=") {
			t.Fatalf("nested attach inherited %s", pair)
		}
	}
	live = false
	_, _, _, err = attachPlan(t.Context(), store, router, id)
	if err == nil || !strings.Contains(err.Error(), "qm continue") {
		t.Fatalf("stopped attach error = %v", err)
	}
}

func TestSessionClosedLockTimeoutExitsZero(t *testing.T) {
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id := "qm-held-cleanup-lock"
	entered, release := make(chan struct{}), make(chan struct{})
	go func() { _ = store.WithLifecycleLock(id, func() error { close(entered); <-release; return nil }) }()
	<-entered
	defer close(release)
	runner := &mockRunner{fn: func(context.Context, ...string) (string, error) { return "", errors.New("unexpected tmux call") }}
	client := tmux.NewClient(runner)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": client, "test_named": client}, func() string { return "default" }, nil)
	root := NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
	defer cancel()
	root.SetContext(ctx)
	root.SetArgs([]string{"tmux", "session-closed", "--server", "test_named", "--", id})
	if err := root.Execute(); err != nil {
		t.Fatalf("session-closed command returned %v", err)
	}
}
