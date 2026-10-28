package prstatus

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type jobTmux func(context.Context, ...string) (string, error)

func (f jobTmux) Run(ctx context.Context, args ...string) (string, error) { return f(ctx, args...) }

func jobFixture(t *testing.T) (*Job, *state.Store, *time.Time, *map[string]bool) {
	t.Helper()
	root := t.TempDir()
	store := state.OpenStore(root)
	for _, id := range []string{"qm-live", "qm-dead"} {
		if err := store.Create(state.Manifest{SessionID: id}); err != nil {
			t.Fatal(err)
		}
	}
	live := map[string]bool{"qm-live": true}
	client := tmux.NewClient(jobTmux(func(_ context.Context, args ...string) (string, error) {
		if args[0] != "list-sessions" {
			t.Fatalf("tmux args=%v", args)
		}
		names := []string{}
		for id, ok := range live {
			if ok {
				names = append(names, id)
			}
		}
		return strings.Join(names, "\n"), nil
	}))
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	j := NewJob(root, client, nil)
	j.Now = func() time.Time { return now }
	return j, store, &now, &live
}
func jobWatch(t *testing.T, store *state.Store, id, ref string) string {
	t.Helper()
	pr, err := state.ParsePullRequestRef(ref)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), id, pr, time.Now()); err != nil {
		t.Fatal(err)
	}
	return pr.Key
}
func jobGH(t *testing.T, j *Job, calls *[]string, stateByHost map[string]string, updated map[string]time.Time) {
	t.Helper()
	j.RunGH = func(_ context.Context, host, query string) ([]byte, []byte, error) {
		*calls = append(*calls, host)
		parts := []string{`"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-27T00:00:00Z"}`}
		count := strings.Count(query, "repository(owner:")
		for i := 0; i < count; i++ {
			parts = append(parts, fmt.Sprintf(`"p%d":{"pullRequest":{"title":"PR","state":%q,"updatedAt":%q,"commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}`, i, stateByHost[host], updated[host].Format(time.RFC3339)))
		}
		return []byte(`{"data":{` + strings.Join(parts, ",") + `}}`), nil, nil
	}
}

func TestJobPollsExistingWatchAfterLegacyTimestamp(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	updated := now.Add(-2 * time.Hour).Format(time.RFC3339)
	legacy := fmt.Sprintf(`{%q:{"title":"PR","state":"open","updated_at":%q,"comments":1,"review":"none","ci":"none","fetched_at":%q}}`, pr.Key, updated, now.Add(-time.Hour).Format(time.RFC3339))
	if err := os.WriteFile(state.PullRequestStatusPath(store.Root()), []byte(legacy), 0600); err != nil {
		t.Fatal(err)
	}
	oldAt := now.Add(-45 * time.Minute).Format(time.RFC3339)
	newAt := now.Add(-30 * time.Minute).Format(time.RFC3339)
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "old-comment", Kind: "comment", OccurredAt: oldAt}}, map[string]string{"comments": "old-comment"}); err != nil {
		t.Fatal(err)
	}
	if _, err := state.ReadPullRequestEvents(store.Root(), pr.Key, "qm-live", true); err != nil {
		t.Fatal(err)
	}
	if err := state.AdvancePullRequestAlert(store.Root(), pr.Key, "qm-live", 1); err != nil {
		t.Fatal(err)
	}
	j.RunGH = func(_ context.Context, _, query string) ([]byte, []byte, error) {
		if strings.Contains(query, "p0: repository") {
			return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100},"p0":{"pullRequest":{"title":"PR","state":"OPEN","updatedAt":%q,"totalCommentsCount":2}}}}`, updated)), nil, nil
		}
		if strings.Contains(query, "timelineItems") {
			t.Fatal("existing status was mistaken for a first fetch")
		}
		source, nodes := "reviews", `[]`
		if strings.Contains(query, "comments(last:") {
			source = "comments"
			nodes = fmt.Sprintf(`[{"id":"old-comment","createdAt":%q},{"id":"new-comment","createdAt":%q}]`, oldAt, newAt)
		}
		return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100},"repository":{"pullRequest":{"%s":{"nodes":%s,"pageInfo":{"hasPreviousPage":false}}}}}}`, source, nodes)), nil, nil
	}
	j.RunREST = func(context.Context, string, string) ([]byte, []byte, error) { return []byte(`[]`), nil, nil }
	j.SendAlert = func(context.Context, string, string) (bool, error) { return false, nil }
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	status, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil || status[pr.Key].ChangedAt != now.Format(time.RFC3339) {
		t.Fatalf("status=%#v err=%v", status[pr.Key], err)
	}
	log, err := state.LoadPullRequestEventLog(store.Root(), pr.Key)
	if err != nil || log.Seq != 2 || len(log.Events) != 2 || log.Events[1].ID != "new-comment" || log.LastIDs["comments"] != "new-comment" || log.Cursors["qm-live"] != (state.PullRequestEventCursor{AlertedSeq: 1, ReadSeq: 1}) {
		t.Fatalf("event log=%#v err=%v", log, err)
	}
}

func TestJobHoldsThenCoalescesPendingAlert(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	j.RunGH = func(_ context.Context, _, query string) ([]byte, []byte, error) {
		if strings.Contains(query, "p0: repository") {
			return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-28T00:00:00Z"},"p0":{"pullRequest":{"title":"PR","state":"OPEN","updatedAt":%q,"totalCommentsCount":1}}}}`, now.Format(time.RFC3339))), nil, nil
		}
		source := "comments"
		nodes := `[{"id":"comment-1","body":"please fix","createdAt":"2026-10-26T00:01:00Z","author":{"login":"reviewer"}}]`
		if strings.Contains(query, "reviews(last:") {
			source, nodes = "reviews", `[]`
		}
		return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-28T00:00:00Z"},"repository":{"pullRequest":{"%s":{"nodes":%s,"pageInfo":{"hasPreviousPage":false,"startCursor":""}}}}}}`, source, nodes)), nil, nil
	}
	j.RunREST = func(context.Context, string, string) ([]byte, []byte, error) { return []byte(`[]`), nil, nil }
	ready := false
	var sent []string
	j.SendAlert = func(_ context.Context, id, text string) (bool, error) {
		if id != "qm-live" {
			t.Fatalf("alert recipient = %s", id)
		}
		if ready {
			sent = append(sent, text)
		}
		return ready, nil
	}
	for tick := 0; tick < 3; tick++ {
		if tick == 1 {
			ready = true
		}
		if err := j.step(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if len(sent) != 1 || !strings.Contains(sent[0], "1 comment") {
		t.Fatalf("alerts = %#v", sent)
	}
	log, err := state.LoadPullRequestEventLog(store.Root(), pr.Key)
	if err != nil || log.Seq != 1 || log.Cursors["qm-live"].AlertedSeq != 1 {
		t.Fatalf("event log = %#v, %v", log, err)
	}
}

func TestMergedPRKeepsPendingAlertUntilDelivered(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "state:merged", Kind: "state", State: "merged", OccurredAt: now.Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {State: "merged"}}, nil); err != nil {
		t.Fatal(err)
	}
	if !j.HasWork() {
		t.Fatal("pending merged alert did not keep job alive")
	}
	called := 0
	j.SendAlert = func(context.Context, string, string) (bool, error) { called++; return true, nil }
	if err := j.step(context.Background()); err != nil || called != 1 || j.HasWork() {
		t.Fatalf("merged delivery: calls=%d work=%v err=%v", called, j.HasWork(), err)
	}
}

func TestStoppedPendingAlertWaitsForLiveWatcher(t *testing.T) {
	t.Parallel()
	j, store, now, live := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "state:merged", Kind: "state", State: "merged", OccurredAt: now.Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{pr.Key: {State: "merged"}}, nil); err != nil {
		t.Fatal(err)
	}
	(*live)["qm-live"] = false
	if j.HasWork() {
		t.Fatal("stopped watcher kept daemon work alive")
	}
	called := 0
	j.SendAlert = func(context.Context, string, string) (bool, error) { called++; return true, nil }
	if err := j.deliverPending(context.Background()); err != nil || called != 0 {
		t.Fatalf("stopped delivery: calls=%d err=%v", called, err)
	}
	(*live)["qm-live"] = true
	resumed := NewJob(store.Root(), j.Tmux, nil) // a daemon started after the session resumes
	resumed.Now, resumed.SendAlert = j.Now, j.SendAlert
	if !resumed.HasWork() {
		t.Fatal("resumed watcher lost pending work")
	}
	if err := resumed.step(context.Background()); err != nil || called != 1 || resumed.HasWork() {
		t.Fatalf("resumed delivery: calls=%d work=%v err=%v", called, resumed.HasWork(), err)
	}
}

func TestAlertSendErrorIsRateLimitedAndRetried(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "comment-1", Kind: "comment", OccurredAt: now.Format(time.RFC3339Nano)}}, nil); err != nil {
		t.Fatal(err)
	}
	called := 0
	j.SendAlert = func(context.Context, string, string) (bool, error) {
		called++
		return false, errors.New("permanent send failure")
	}
	key := pr.Key + "\x00qm-live"
	for i := 0; i < 2; i++ {
		if err := j.deliverPending(context.Background()); err != nil {
			t.Fatal(err)
		}
	}
	if called != 2 || !j.alertErrorLogged[key].Equal(*now) {
		t.Fatalf("retry count=%d last log=%v", called, j.alertErrorLogged[key])
	}
	log, err := state.LoadPullRequestEventLog(store.Root(), pr.Key)
	if err != nil || log.Cursors["qm-live"].AlertedSeq != 0 {
		t.Fatalf("failed send advanced cursor=%#v err=%v", log.Cursors, err)
	}
	*now = now.Add(time.Minute)
	if err := j.deliverPending(context.Background()); err != nil || !j.alertErrorLogged[key].Equal(*now) {
		t.Fatalf("later retry: last log=%v err=%v", j.alertErrorLogged[key], err)
	}
}

func TestRemovedWatchDoesNotStopOtherAlerts(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	refs := []state.PullRequest{}
	for _, ref := range []string{"owner/one#1", "owner/two#2"} {
		pr, _ := state.ParsePullRequestRef(ref)
		refs = append(refs, pr)
		if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, now.Add(-time.Hour)); err != nil {
			t.Fatal(err)
		}
		if _, err := state.RecordPullRequestEvents(store.Root(), pr.Key, []state.PullRequestEvent{{ID: "comment-1", Kind: "comment", OccurredAt: now.Format(time.RFC3339Nano)}}, nil); err != nil {
			t.Fatal(err)
		}
	}
	called := 0
	j.SendAlert = func(context.Context, string, string) (bool, error) {
		called++
		if called == 1 {
			if removed, err := state.UnwatchPullRequest(store.Root(), "qm-live", refs[0].Key); err != nil || !removed {
				t.Fatalf("remove during send: removed=%v err=%v", removed, err)
			}
		}
		return true, nil
	}
	if err := j.deliverPending(context.Background()); err != nil || called != 2 {
		t.Fatalf("delivery after watch removal: calls=%d err=%v", called, err)
	}
	log, err := state.LoadPullRequestEventLog(store.Root(), refs[1].Key)
	if err != nil || log.Cursors["qm-live"].AlertedSeq != 1 {
		t.Fatalf("second watch cursor=%#v err=%v", log.Cursors, err)
	}
}
func TestJobCadenceLivenessAndMerged(t *testing.T) {
	t.Parallel()
	j, store, now, live := jobFixture(t)
	hot := jobWatch(t, store, "qm-live", "owner/hot#1")
	cold := jobWatch(t, store, "qm-live", "https://enterprise.test/o/r/pull/2")
	jobWatch(t, store, "qm-dead", "https://dead.test/o/r/pull/3")
	calls := []string{}
	jobGH(t, j, &calls, map[string]string{"github.com": "OPEN", "enterprise.test": "CLOSED", "dead.test": "OPEN"}, map[string]time.Time{"github.com": *now, "enterprise.test": now.Add(-time.Hour), "dead.test": now.Add(-time.Hour)})
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || !j.HasWork() {
		t.Fatalf("calls=%v hasWork=%v", calls, j.HasWork())
	}
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	statuses[hot] = state.PullRequestStatus{State: "open", CI: "pending", UpdatedAt: now.Format(time.RFC3339)}
	statuses[cold] = state.PullRequestStatus{State: "closed", UpdatedAt: now.Add(-time.Hour).Format(time.RFC3339)}
	if err := state.SavePullRequestStatuses(store.Root(), statuses, nil); err != nil {
		t.Fatal(err)
	}
	j.next = map[string]time.Time{}
	calls = nil
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := j.next["github.com"].Sub(*now); got != 20*time.Second {
		t.Fatalf("hot cadence=%v", got)
	}
	if got := j.next["enterprise.test"].Sub(*now); got != 60*time.Second {
		t.Fatalf("closed cadence=%v", got)
	}
	*now = now.Add(21 * time.Second)
	calls = nil
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || calls[0] != "github.com" {
		t.Fatalf("independent host schedule=%v", calls)
	}
	statuses[hot] = state.PullRequestStatus{State: "merged"}
	if err := state.SavePullRequestStatuses(store.Root(), statuses, nil); err != nil {
		t.Fatal(err)
	}
	*now = now.Add(time.Minute)
	calls = nil
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || calls[0] != "enterprise.test" {
		t.Fatalf("merged should drop; closed stays: %v", calls)
	}
	if !j.HasWork() {
		t.Fatal("closed PR lost work")
	}
	(*live)["qm-live"] = false
	if j.HasWork() {
		t.Fatal("dead watcher counted")
	}
	(*live)["qm-live"] = true
	statuses[cold] = state.PullRequestStatus{State: "merged"}
	if err := state.SavePullRequestStatuses(store.Root(), statuses, nil); err != nil {
		t.Fatal(err)
	}
	if j.HasWork() {
		t.Fatal("merged PR counted")
	}
}

func TestJobNoTmuxServerHasNoWork(t *testing.T) {
	t.Parallel()
	j, store, _, _ := jobFixture(t)
	jobWatch(t, store, "qm-live", "owner/repo#1")
	j.Tmux = tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running on /tmp/tmux-test/default"}
	}))
	if j.HasWork() {
		t.Fatal("absent tmux server kept job alive")
	}
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		t.Fatal("GitHub called with no live watchers")
		return nil, nil, nil
	}
	if err := j.step(context.Background()); err != nil {
		t.Fatalf("absent tmux server treated as job error: %v", err)
	}
	j.Tmux = tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) { return "", syscall.EAGAIN }))
	if !j.HasWork() {
		t.Fatal("temporary process-spawn failure dropped watched work")
	}
}
func TestJobBackoffWakeAndDone(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	key := jobWatch(t, store, "qm-live", "owner/repo#1")
	calls := 0
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		calls++
		if calls <= 3 {
			return nil, []byte("temporary failure"), errors.New("failed")
		}
		return []byte(`{"data":{"p0":{"pullRequest":{"state":"OPEN"}}}}`), nil, nil
	}
	for want, delay := range []time.Duration{5 * time.Second, 10 * time.Second, 20 * time.Second} {
		j.Notify([]string{key})
		if err := j.step(context.Background()); err != nil {
			t.Fatal(err)
		}
		if calls != want+1 || j.blocked["github.com"].Sub(*now) != delay {
			t.Fatalf("retry %d calls=%d delay=%v", want, calls, j.blocked["github.com"].Sub(*now))
		}
		j.Notify([]string{key})
		if err := j.step(context.Background()); err != nil {
			t.Fatal(err)
		}
		if calls != want+1 {
			t.Fatal("wake bypassed backoff")
		}
		*now = now.Add(delay)
	}
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 4 || j.failures["github.com"] != 0 {
		t.Fatalf("success did not reset: %d %d", calls, j.failures["github.com"])
	}
	j.next["github.com"] = now.Add(time.Hour)
	writeDone := func(value string, stamp time.Time) {
		t.Helper()
		path := state.SessionStatePath(store.Root(), "qm-live")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		data := fmt.Sprintf(`{"session_id":"qm-live","panes":{"agent":{"state":%q,"last_event":%q}}}`, value, stamp.Format(time.RFC3339))
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	writeDone("idle", *now)
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	writeDone("done", now.Add(time.Second))
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if calls != 5 {
		t.Fatalf("done did not wake: calls=%d", calls)
	}
}

func TestJobCancellationPreservesStatus(t *testing.T) {
	t.Parallel()
	j, store, _, _ := jobFixture(t)
	key := jobWatch(t, store, "qm-live", "owner/repo#1")
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{key: {Title: "old"}}, nil); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		cancel()
		return []byte(`{"data":{"p0":{"pullRequest":{"title":"new","state":"OPEN"}}}}`), nil, nil
	}
	if err := j.step(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("step=%v", err)
	}
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	if statuses[key].Title != "old" {
		t.Fatalf("status changed on canceled fetch: %#v", statuses[key])
	}
}

func TestJobRateHintAndExponentialCap(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name     string
		response []byte
		want     time.Duration
		attempts int
	}{
		{"retry-after", []byte("HTTP/2 429\nretry-after: 90\n\n{\"message\":\"rate limit\"}"), 90 * time.Second, 1},
		{"exponential cap", nil, 5 * time.Minute, 8},
	} {
		t.Run(tc.name, func(t *testing.T) {
			j, store, now, _ := jobFixture(t)
			key := jobWatch(t, store, "qm-live", "owner/repo#1")
			calls := 0
			j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
				calls++
				return tc.response, []byte("failure"), errors.New("failed")
			}
			for attempt := 0; attempt < tc.attempts; attempt++ {
				j.Notify([]string{key})
				if err := j.step(context.Background()); err != nil {
					t.Fatal(err)
				}
				delay := j.blocked["github.com"].Sub(*now)
				if attempt == tc.attempts-1 && delay != tc.want {
					t.Fatalf("delay=%v want=%v", delay, tc.want)
				}
				j.Notify([]string{key})
				if err := j.step(context.Background()); err != nil {
					t.Fatal(err)
				}
				if calls != attempt+1 {
					t.Fatalf("wake bypassed hint: calls=%d", calls)
				}
				*now = now.Add(delay)
			}
		})
	}
}

func TestJobRefreshWaitsForFetch(t *testing.T) {
	t.Parallel()
	j, store, _, _ := jobFixture(t)
	key := jobWatch(t, store, "qm-live", "owner/repo#1")
	calls := make(chan struct{}, 2)
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		calls <- struct{}{}
		return []byte(`{"data":{"p0":{"pullRequest":{"title":"fresh","state":"OPEN"}}}}`), nil, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan struct{})
	go func() { _ = j.Run(ctx); close(stopped) }()
	select {
	case <-calls:
	case <-time.After(5 * time.Second):
		t.Fatal("initial fetch missing")
	}
	result := make(chan error, 1)
	go func() {
		hosts, err := j.Refresh(ctx, []string{key})
		if err == nil && len(hosts) != 1 {
			err = fmt.Errorf("hosts=%v", hosts)
		}
		result <- err
	}()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("refresh did not finish")
	}
	select {
	case <-calls:
	default:
		t.Fatal("refresh returned before fetch")
	}
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil || statuses[key].Title != "fresh" {
		t.Fatalf("status=%v err=%v", statuses, err)
	}
	cancel()
	select {
	case <-stopped:
	case <-time.After(5 * time.Second):
		t.Fatal("job did not stop")
	}
}

func TestJobRefreshInsideBackoffReturnsCurrentHostState(t *testing.T) {
	t.Parallel()
	j, store, now, _ := jobFixture(t)
	key := jobWatch(t, store, "qm-live", "owner/repo#1")
	calls := 0
	j.RunGH = func(context.Context, string, string) ([]byte, []byte, error) {
		calls++
		return []byte("HTTP/2 429\nretry-after: 90\n\n{\"message\":\"rate limit\"}"), []byte("rate limit"), errors.New("failed")
	}
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan map[string]HostResult, 1)
	go func() { hosts, _ := j.Refresh(ctx, []string{key}); result <- hosts }()
	select {
	case <-j.signal:
	case <-time.After(5 * time.Second):
		t.Fatal("wake not queued")
	}
	if err := j.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case hosts := <-result:
		item := hosts["github.com"]
		if calls != 1 || item.Error == "" || item.BackoffUntil != now.Add(90*time.Second).Format(time.RFC3339) || item.CheckedAt != "" {
			t.Fatalf("calls=%d host=%#v", calls, item)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("refresh waited inside backoff")
	}
}
