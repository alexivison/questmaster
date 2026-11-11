package prstatus

import (
	"context"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestPRJobDeliversToEitherServer(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{SessionID: "qm-named", TmuxServer: "questmaster"}); err != nil {
		t.Fatal(err)
	}
	pr, err := state.ParsePullRequestRef("owner/repo#12")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-named", pr, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "state:merged", Kind: "state", State: "merged", OccurredAt: time.Now().Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {State: "merged"}}, nil); err != nil {
		t.Fatal(err)
	}
	legacy := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))
	named := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) { return "qm-named", nil }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": legacy, "questmaster": named}, func() string { return "dev_previous" }, nil)
	job := NewJob(store.Root(), legacy, nil, router)
	called := 0
	job.SendAlert = func(context.Context, string, string) (message.Delivery, error) {
		called++
		return message.DeliverySubmitted, nil
	}
	if !job.HasWork() {
		t.Fatal("named watcher should keep pending delivery alive")
	}
	if err := job.deliverPending(t.Context()); err != nil || called != 1 {
		t.Fatalf("delivery calls=%d err=%v", called, err)
	}
}

func TestPRJobRequiresWatcherOnRecordedServer(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{TmuxServer: "dev_previous", SessionID: "qm-old"}); err != nil {
		t.Fatal(err)
	}
	pr, err := state.ParsePullRequestRef("owner/repo#12")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-old", pr, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "state:merged", Kind: "state", State: "merged", OccurredAt: time.Now().Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {State: "merged"}}, nil); err != nil {
		t.Fatal(err)
	}
	legacy := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))
	named := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) { return "qm-old", nil }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": legacy, "questmaster": named}, func() string { return "dev_previous" }, nil)
	job := NewJob(store.Root(), legacy, nil, router)
	if job.HasWork() {
		t.Fatal("watcher exists only on the wrong server")
	}
	called := false
	job.SendAlert = func(context.Context, string, string) (message.Delivery, error) {
		called = true
		return message.DeliverySubmitted, nil
	}
	if err := job.deliverPending(t.Context()); err != nil || called {
		t.Fatalf("delivery called=%v err=%v", called, err)
	}
}

func TestPRJobRequiresRouter(t *testing.T) {
	client := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	job := NewJob(t.TempDir(), client, nil)
	if _, err := job.liveIDs(t.Context(), []string{"qm-named"}); err == nil {
		t.Fatal("nil router used a default-only view")
	}
}
