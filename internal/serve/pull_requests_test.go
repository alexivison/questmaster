//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/state"
)

func TestPRRefreshScopesAndWaitsForStatus(t *testing.T) {
	env := seedServeFixture(t)
	ref, _ := state.ParsePullRequestRef("owner/repo#42")
	other, _ := state.ParsePullRequestRef("owner/repo#43")
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-demo", ref, env.now); err != nil {
		t.Fatal(err)
	}
	if err := env.store.Create(state.Manifest{SessionID: "qm-other"}); err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-other", other, env.now); err != nil {
		t.Fatal(err)
	}
	called := false
	srv := &Server{Snapshotter: NewSnapshotter(env.store, env.tmuxClient, nil), PRRefresh: func(_ context.Context, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		called = true
		if !wait {
			t.Fatal("app refresh did not wait")
		}
		if len(keys) != 1 || keys[0] != ref.Key {
			t.Fatalf("keys=%v", keys)
		}
		if err := state.SavePullRequestStatuses(env.store.Root(), map[string]state.PullRequestStatus{ref.Key: {Title: "fresh", State: "open"}}, nil); err != nil {
			t.Fatal(err)
		}
		return map[string]prstatus.HostResult{"github.com": {}}, nil
	}}
	response := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"session_id":"qm-demo"}`)})
	if response.OK == nil || !*response.OK || !called {
		t.Fatalf("refresh=%#v called=%v", response, called)
	}
	data, _ := json.Marshal(response.Data)
	if !bytes.Contains(data, []byte(`"title":"fresh"`)) || bytes.Contains(data, []byte(other.Key)) {
		t.Fatalf("data=%s", data)
	}
	explicit := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"session_id":"qm-demo","wait":true}`)})
	if explicit.OK == nil || !*explicit.OK {
		t.Fatalf("the app's own request (session_id, wait: true) refused: %#v", explicit)
	}
	denied := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"session_id":"qm-demo","keys":["github.com/owner/repo#43"]}`)})
	if denied.OK == nil || *denied.OK {
		t.Fatalf("foreign key accepted: %#v", denied)
	}
	if _, err := state.UnwatchPullRequest(env.store.Root(), "qm-demo", ref.Key); err != nil {
		t.Fatal(err)
	}
	srv.PRRefresh = func(_ context.Context, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		if !wait {
			t.Fatal("empty app refresh did not wait")
		}
		if len(keys) != 0 {
			t.Fatalf("empty scope keys=%v", keys)
		}
		return map[string]prstatus.HostResult{}, nil
	}
	empty := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"session_id":"qm-demo"}`)})
	data, _ = json.Marshal(empty.Data)
	if empty.OK == nil || !*empty.OK || !bytes.Contains(data, []byte(`"pull_requests":[]`)) {
		t.Fatalf("empty refresh=%s error=%s", data, empty.Error)
	}
}

func TestPRRefreshWithoutSessionQueuesWatchedKey(t *testing.T) {
	env := seedServeFixture(t)
	ref, _ := state.ParsePullRequestRef("owner/repo#42")
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-demo", ref, env.now); err != nil {
		t.Fatal(err)
	}
	srv := &Server{Snapshotter: NewSnapshotter(env.store, env.tmuxClient, nil), PRRefresh: func(_ context.Context, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		if wait || len(keys) != 1 || keys[0] != ref.Key {
			return nil, fmt.Errorf("wrong wake: wait=%v keys=%v", wait, keys)
		}
		return map[string]prstatus.HostResult{}, nil
	}}
	response := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"keys":["github.com/owner/repo#42"],"wait":false}`)})
	if response.OK == nil || !*response.OK {
		t.Fatalf("async wake failed: %s", response.Error)
	}
	if err := env.store.Create(state.Manifest{SessionID: "qm-other"}); err != nil {
		t.Fatal(err)
	}
	other, _ := state.ParsePullRequestRef("owner/repo#43")
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-other", other, env.now); err != nil {
		t.Fatal(err)
	}
	srv.PRRefresh = func(_ context.Context, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		if !wait || len(keys) != 1 || keys[0] != other.Key {
			t.Fatalf("unscoped refresh wait=%v keys=%v", wait, keys)
		}
		return map[string]prstatus.HostResult{"github.com": {}}, nil
	}
	otherResponse := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"keys":["github.com/owner/repo#43"],"wait":true}`)})
	if otherResponse.OK == nil || !*otherResponse.OK {
		t.Fatalf("unscoped watched key failed: %s", otherResponse.Error)
	}
	denied := srv.HandleRequest(context.Background(), Request{Method: "pr.refresh", Data: json.RawMessage(`{"keys":["github.com/owner/repo#99"],"wait":false}`)})
	if denied.OK == nil || *denied.OK {
		t.Fatalf("unwatched key accepted: %#v", denied)
	}
}

func TestPullRequestsScopeAndRevision(t *testing.T) {
	env := seedServeFixture(t)
	worker := state.Manifest{SessionID: "qm-worker", SessionType: "worker"}
	worker.SetExtra("parent_session", "qm-demo")
	if err := env.store.Create(worker); err != nil {
		t.Fatal(err)
	}
	if err := env.store.Update("qm-demo", func(m *state.Manifest) { m.Workers = []string{"qm-worker"} }); err != nil {
		t.Fatal(err)
	}
	other := state.Manifest{SessionID: "qm-other"}
	if err := env.store.Create(other); err != nil {
		t.Fatal(err)
	}
	ref1, _ := state.ParsePullRequestRef("owner/repo#1")
	ref2, _ := state.ParsePullRequestRef("owner/repo#2")
	ref3, _ := state.ParsePullRequestRef("owner/repo#3")
	for _, item := range []struct {
		id  string
		ref state.PullRequest
	}{{"qm-demo", ref1}, {"qm-worker", ref1}, {"qm-worker", ref2}, {"qm-other", ref3}} {
		if _, err := state.WatchPullRequest(env.store.Root(), item.id, item.ref, env.now); err != nil {
			t.Fatal(err)
		}
	}
	snapshotter := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	srv := &Server{Snapshotter: snapshotter}
	request := func(id string) []state.PullRequest {
		t.Helper()
		raw, _ := json.Marshal(pullRequestsPayload{SessionID: id})
		env := srv.HandleRequest(context.Background(), Request{Method: topicPullRequests, Data: raw})
		if env.OK == nil || !*env.OK {
			t.Fatalf("request %s: %s", id, env.Error)
		}
		return env.Data.([]state.PullRequest)
	}
	master := request("qm-demo")
	if len(master) != 2 || len(master[0].Watchers) != 2 || len(master[1].Watchers) != 1 {
		t.Fatalf("master PRs = %#v", master)
	}
	workerPRs := request("qm-worker")
	if len(workerPRs) != 2 || len(workerPRs[0].Watchers) != 1 {
		t.Fatalf("worker PRs = %#v", workerPRs)
	}
	// The tracker derives scope from rows, without consulting the master's worker list.
	if err := env.store.Update("qm-demo", func(m *state.Manifest) { m.Workers = nil }); err != nil {
		t.Fatal(err)
	}
	initial, err := snapshotter.TrackerForChange(Change{})
	if err != nil {
		t.Fatal(err)
	}
	masterIndex := trackerSessionIndex(initial.Sessions, "qm-demo")
	if masterIndex < 0 {
		t.Fatal("master row missing")
	}
	if initial.Sessions[masterIndex].PullRequestsRev != pullRequestsRevision(master) {
		t.Fatalf("rev = %q want %q", initial.Sessions[masterIndex].PullRequestsRev, pullRequestsRevision(master))
	}
	stable, err := snapshotter.TrackerForChange(Change{Topics: []string{topicTracker}, BroadTracker: true})
	if err != nil {
		t.Fatal(err)
	}
	if stable.Sessions[trackerSessionIndex(stable.Sessions, "qm-demo")].PullRequestsRev != initial.Sessions[masterIndex].PullRequestsRev {
		t.Fatal("unchanged set changed rev")
	}
	if err := state.SavePullRequestStatuses(env.store.Root(), map[string]state.PullRequestStatus{ref1.Key: {Title: "Updated", State: "open", ChangedAt: env.now.Format(time.RFC3339)}}, nil); err != nil {
		t.Fatal(err)
	}
	withStatus, err := snapshotter.TrackerForChange(Change{Topics: []string{topicTracker}, BroadTracker: true})
	if err != nil {
		t.Fatal(err)
	}
	if withStatus.Sessions[masterIndex].PullRequestsRev == initial.Sessions[masterIndex].PullRequestsRev || request("qm-demo")[0].Status.Title != "Updated" {
		t.Fatal("status did not reach response and tracker revision")
	}
	if _, err := state.UnwatchPullRequest(env.store.Root(), "qm-worker", ref2.Key); err != nil {
		t.Fatal(err)
	}
	changed, err := snapshotter.TrackerForChange(Change{Topics: []string{topicTracker}, BroadTracker: true})
	if err != nil {
		t.Fatal(err)
	}
	if changed.Sessions[trackerSessionIndex(changed.Sessions, "qm-demo")].PullRequestsRev == initial.Sessions[masterIndex].PullRequestsRev {
		t.Fatal("changed set kept rev")
	}
	if err := env.store.Delete("qm-worker"); err != nil {
		t.Fatal(err)
	}
	master = request("qm-demo")
	if len(master) != 1 || len(master[0].Watchers) != 1 {
		t.Fatalf("dead worker shown: %#v", master)
	}
}

func TestPullRequestsRegistryRewritePushesTracker(t *testing.T) {
	env := seedServeFixture(t)
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	source, err := NewFileChangeSource(ctx, snap, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	changes, unsubscribe := source.Subscribe(ctx)
	defer unsubscribe()
	srv := &Server{Snapshotter: snap}
	var first bytes.Buffer
	if err := srv.pushChanged(ctx, json.NewEncoder(&first), []string{topicTracker}, map[string][]byte{}, allTopicsChange()); err != nil {
		t.Fatal(err)
	}
	ref, _ := state.ParsePullRequestRef("owner/repo#1")
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-demo", ref, env.now); err != nil {
		t.Fatal(err)
	}
	select {
	case change := <-changes:
		if !change.BroadTracker || !change.Affects(topicTracker) {
			t.Fatalf("change = %#v", change)
		}
		var output bytes.Buffer
		var baseline Envelope
		if err := json.Unmarshal(bytes.TrimSpace(first.Bytes()), &baseline); err != nil {
			t.Fatal(err)
		}
		baselineBytes, _ := json.Marshal(baseline.Data)
		if err := srv.pushChanged(ctx, json.NewEncoder(&output), []string{topicTracker}, map[string][]byte{topicTracker: baselineBytes}, change); err != nil {
			t.Fatal(err)
		}
		var pushed struct {
			Data TrackerSnapshot `json:"data"`
		}
		if err := json.Unmarshal(output.Bytes(), &pushed); err != nil {
			t.Fatalf("no tracker push: %v", err)
		}
		if pushed.Data.Sessions[trackerSessionIndex(pushed.Data.Sessions, "qm-demo")].PullRequestsRev == "" {
			t.Fatal("push lacked PR revision")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("registry rewrite did not publish")
	}
}

func TestPullRequestStatusRewritePushesTracker(t *testing.T) {
	env := seedServeFixture(t)
	ref, _ := state.ParsePullRequestRef("owner/repo#1")
	if _, err := state.WatchPullRequest(env.store.Root(), "qm-demo", ref, env.now); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	snap := NewSnapshotter(env.store, env.tmuxClient, func() time.Time { return env.now })
	source, err := NewFileChangeSource(ctx, snap, time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	changes, unsubscribe := source.Subscribe(ctx)
	defer unsubscribe()
	srv := &Server{Snapshotter: snap}
	baseline, err := snap.TrackerForChange(Change{})
	if err != nil {
		t.Fatal(err)
	}
	oldRev := baseline.Sessions[trackerSessionIndex(baseline.Sessions, "qm-demo")].PullRequestsRev
	if err := state.SavePullRequestStatuses(env.store.Root(), map[string]state.PullRequestStatus{ref.Key: {Title: "New status", ChangedAt: env.now.Format(time.RFC3339)}}, nil); err != nil {
		t.Fatal(err)
	}
	select {
	case change := <-changes:
		if !change.BroadTracker || !change.Affects(topicTracker) {
			t.Fatalf("change=%#v", change)
		}
		var output bytes.Buffer
		baselineBytes, _ := json.Marshal(baseline)
		if err := srv.pushChanged(ctx, json.NewEncoder(&output), []string{topicTracker}, map[string][]byte{topicTracker: baselineBytes}, change); err != nil {
			t.Fatal(err)
		}
		var pushed struct {
			Data TrackerSnapshot `json:"data"`
		}
		if err := json.Unmarshal(output.Bytes(), &pushed); err != nil {
			t.Fatalf("no tracker push: %v", err)
		}
		if pushed.Data.Sessions[trackerSessionIndex(pushed.Data.Sessions, "qm-demo")].PullRequestsRev == oldRev {
			t.Fatal("status push kept old revision")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("status rewrite did not publish")
	}
}
