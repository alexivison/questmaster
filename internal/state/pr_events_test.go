package state

import (
	"maps"
	"strings"
	"testing"
	"time"
)

func TestPullRequestEventsDedupeBaselineAndCursors(t *testing.T) {
	t.Parallel()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"qm-one", "qm-two"} {
		if err := store.Create(Manifest{SessionID: id}); err != nil {
			t.Fatal(err)
		}
	}
	ref, _ := ParsePullRequestRef("owner/repo#12")
	baseline := time.Date(2026, 10, 27, 1, 0, 0, 0, time.UTC)
	if _, err := WatchPullRequest(store.Root(), "qm-one", ref, baseline); err != nil {
		t.Fatal(err)
	}
	items := []PullRequestEvent{
		{ID: "old", Kind: "comment", OccurredAt: baseline.Add(-time.Minute).Format(time.RFC3339Nano), Body: "old"},
		{ID: "new", Kind: "comment", OccurredAt: baseline.Add(time.Minute).Format(time.RFC3339Nano), Body: "```unsafe```"},
		{ID: "ci:sha:success", Kind: "ci", OccurredAt: baseline.Add(time.Minute).Format(time.RFC3339Nano), Result: "success"},
	}
	if added, err := RecordPullRequestEvents(store.Root(), ref.Key, items, map[string]string{"comments": "new"}); err != nil || len(added) != 3 {
		t.Fatalf("record = %v, %v", added, err)
	}
	if added, err := RecordPullRequestEvents(store.Root(), ref.Key, items, nil); err != nil || len(added) != 0 {
		t.Fatalf("duplicate record = %v, %v", added, err)
	}
	if _, err := WatchPullRequest(store.Root(), "qm-two", ref, baseline.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	rootAfterRestart := store.Root()
	got, err := ReadPullRequestEvents(rootAfterRestart, ref.Key, "qm-one", true)
	if err != nil || len(got) != 2 || strings.Contains(got[0].Body, "```") || !strings.Contains(got[0].Body, "\\`\\`\\`") {
		t.Fatalf("read = %#v, %v", got, err)
	}
	if got, err := ReadPullRequestEvents(rootAfterRestart, ref.Key, "qm-one", true); err != nil || len(got) != 0 {
		t.Fatalf("reread = %#v, %v", got, err)
	}
	if got, _, err := PullRequestPendingAlerts(rootAfterRestart, ref.Key, "qm-two"); err != nil || len(got) != 0 {
		t.Fatalf("late watcher pending = %#v, %v", got, err)
	}
	if err := AdvancePullRequestAlert(rootAfterRestart, ref.Key, "qm-one", 3); err != nil {
		t.Fatal(err)
	}
	log, err := LoadPullRequestEventLog(rootAfterRestart, ref.Key)
	if err != nil || log.Cursors["qm-one"].ReadSeq != 3 || log.Cursors["qm-one"].AlertedSeq != 3 || log.Cursors["qm-two"].ReadSeq != 3 {
		t.Fatalf("persisted cursors = %#v, %v", log.Cursors, err)
	}
	if _, err := UnwatchPullRequest(rootAfterRestart, "qm-one", ref.Key); err != nil {
		t.Fatal(err)
	}
	log, _ = LoadPullRequestEventLog(rootAfterRestart, ref.Key)
	if _, ok := log.Cursors["qm-one"]; ok {
		t.Fatal("unwatch retained cursor")
	}
}

func TestPullRequestUnreadHistoryIsNeverEvicted(t *testing.T) {
	t.Parallel()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(Manifest{SessionID: "qm-one"}); err != nil {
		t.Fatal(err)
	}
	ref, _ := ParsePullRequestRef("owner/repo#12")
	baseline := time.Date(2026, 10, 27, 0, 0, 0, 0, time.UTC)
	if _, err := WatchPullRequest(store.Root(), "qm-one", ref, baseline); err != nil {
		t.Fatal(err)
	}
	items := make([]PullRequestEvent, PullRequestReadHistoryLimit+10)
	for i := range items {
		items[i] = PullRequestEvent{ID: string(rune(i + 100)), Kind: "comment", OccurredAt: baseline.Add(time.Minute).Format(time.RFC3339Nano)}
	}
	if _, err := RecordPullRequestEvents(store.Root(), ref.Key, items, nil); err != nil {
		t.Fatal(err)
	}
	log, _ := LoadPullRequestEventLog(store.Root(), ref.Key)
	if len(log.Events) != len(items) {
		t.Fatalf("unread retained %d of %d", len(log.Events), len(items))
	}
	if _, err := ReadPullRequestEvents(store.Root(), ref.Key, "qm-one", true); err != nil {
		t.Fatal(err)
	}
	log, _ = LoadPullRequestEventLog(store.Root(), ref.Key)
	if len(log.Events) != PullRequestReadHistoryLimit {
		t.Fatalf("read history = %d", len(log.Events))
	}
	if added, err := RecordPullRequestEvents(store.Root(), ref.Key, items[:1], nil); err != nil || len(added) != 0 {
		t.Fatalf("evicted ID duplicated: %#v, %v", added, err)
	}
}

func TestPullRequestEventsAreReadableWithoutAWatch(t *testing.T) {
	t.Parallel()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(Manifest{SessionID: "qm-watcher"}); err != nil {
		t.Fatal(err)
	}
	ref, _ := ParsePullRequestRef("owner/repo#12")
	baseline := time.Date(2026, 10, 27, 1, 0, 0, 0, time.UTC)
	if _, err := WatchPullRequest(store.Root(), "qm-watcher", ref, baseline); err != nil {
		t.Fatal(err)
	}
	if _, err := RecordPullRequestEvents(store.Root(), ref.Key, []PullRequestEvent{{ID: "one", Kind: "comment", OccurredAt: baseline.Add(time.Minute).Format(time.RFC3339Nano), Body: "```hello```"}}, nil); err != nil {
		t.Fatal(err)
	}
	got, err := ReadPullRequestEvents(store.Root(), ref.Key, "qm-reader", false)
	if err != nil || len(got) != 1 || got[0].Body != "\\`\\`\\`hello\\`\\`\\`" {
		t.Fatalf("read without watch = %#v, %v", got, err)
	}
	log, err := LoadPullRequestEventLog(store.Root(), ref.Key)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := log.Cursors["qm-reader"]; ok {
		t.Fatal("read-only session gained a cursor")
	}
	if _, err := ReadPullRequestEvents(store.Root(), ref.Key, "qm-reader", true); err == nil || !strings.Contains(err.Error(), "--session") {
		t.Fatalf("unread without watch: %v", err)
	}
	if _, err := ReadPullRequestEvents(store.Root(), "github.com/nobody/repo#1", "qm-reader", false); err == nil || !strings.Contains(err.Error(), "no one watches") {
		t.Fatalf("unwatched PR: %v", err)
	}
}

type pullRequestReadStep struct {
	join   string             // a session that starts watching before this step's read
	state  string             // PR status saved before the read
	record []PullRequestEvent // events recorded before the read
	reader string             // session that reads; empty for a setup-only step
	unread bool
	ended  bool // the reader's watch is gone after the read
}

func TestPullRequestReadEndsWatchOnMerge(t *testing.T) {
	t.Parallel()
	baseline := time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC)
	at := func(minutes int) string {
		return baseline.Add(time.Duration(minutes) * time.Minute).Format(time.RFC3339Nano)
	}
	comment := PullRequestEvent{ID: "comment:1", Kind: "comment", OccurredAt: at(1), Body: "looks good"}
	merged := PullRequestEvent{ID: "state:merged:2", Kind: "state", State: "merged", OccurredAt: at(2)}
	closed := PullRequestEvent{ID: "state:closed:2", Kind: "state", State: "closed", OccurredAt: at(2)}
	cases := []struct {
		name     string
		watchers []string
		steps    []pullRequestReadStep
	}{
		{
			name:     "unread read past the merge ends the watch",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment, merged}, reader: "qm-one", unread: true, ended: true},
			},
		},
		{
			name:     "unread read before the merge keeps the watch",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment}, reader: "qm-one", unread: true},
				{record: []PullRequestEvent{merged}, reader: "qm-one", unread: true, ended: true},
			},
		},
		{
			name:     "non-unread read that shows the merge ends the watch",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment, merged}, reader: "qm-one", ended: true},
			},
		},
		{
			name:     "non-unread read before the merge keeps the watch",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment}, reader: "qm-one"},
			},
		},
		{
			name:     "watch joined after the merge ends on an unread read with nothing new",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment}, reader: "qm-one", unread: true},
				{record: []PullRequestEvent{merged}},
				{join: "qm-two"},
				{reader: "qm-two", unread: true, ended: true},
				{reader: "qm-one", unread: true, ended: true},
			},
		},
		{
			name:     "watch on a PR merged before the watch began ends on read",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{state: "merged", reader: "qm-one", unread: true, ended: true},
			},
		},
		{
			name:     "closed PR keeps the watch",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{comment, closed}, state: "closed", reader: "qm-one", unread: true},
			},
		},
		{
			name:     "two watchers each end on their own read",
			watchers: []string{"qm-one", "qm-two"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{merged}},
				{reader: "qm-one", unread: true, ended: true},
				{reader: "qm-two", unread: true, ended: true},
			},
		},
		{
			name:     "a session that does not watch changes nothing",
			watchers: []string{"qm-one"},
			steps: []pullRequestReadStep{
				{record: []PullRequestEvent{merged}, reader: "qm-three"},
				{reader: "qm-one", unread: true, ended: true},
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			runPullRequestReadSteps(t, baseline, tc.watchers, tc.steps)
		})
	}
}

func runPullRequestReadSteps(t *testing.T, baseline time.Time, watchers []string, steps []pullRequestReadStep) {
	t.Helper()
	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := store.Root()
	for _, id := range []string{"qm-one", "qm-two", "qm-three"} {
		if err := store.Create(Manifest{SessionID: id}); err != nil {
			t.Fatal(err)
		}
	}
	ref, _ := ParsePullRequestRef("owner/repo#12")
	want := map[string]bool{}
	watch := func(id string) {
		t.Helper()
		if _, err := WatchPullRequest(root, id, ref, baseline); err != nil {
			t.Fatal(err)
		}
		want[id] = true
	}
	for _, id := range watchers {
		watch(id)
	}
	for i, step := range steps {
		if step.join != "" {
			watch(step.join)
		}
		if step.state != "" {
			if err := SavePullRequestStatuses(root, map[string]PullRequestStatus{ref.Key: {State: step.state}}, nil); err != nil {
				t.Fatal(err)
			}
		}
		if len(step.record) > 0 {
			if _, err := RecordPullRequestEvents(root, ref.Key, step.record, nil); err != nil {
				t.Fatal(err)
			}
		}
		if step.reader != "" {
			if _, err := ReadPullRequestEvents(root, ref.Key, step.reader, step.unread); err != nil {
				t.Fatalf("step %d read by %s: %v", i, step.reader, err)
			}
			if step.ended {
				delete(want, step.reader)
			}
		}
		assertPullRequestWatchers(t, root, ref.Key, want, i)
	}
}

func assertPullRequestWatchers(t *testing.T, root, key string, want map[string]bool, step int) {
	t.Helper()
	registry, err := loadPullRequestRegistry(root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, pr := range registry.PullRequests {
		if pr.Key != key {
			continue
		}
		for _, watcher := range pr.Watchers {
			got[watcher.SessionID] = true
		}
	}
	if !maps.Equal(got, want) {
		t.Fatalf("step %d watchers = %v, want %v", step, got, want)
	}
	if len(want) == 0 && (len(registry.PullRequests) != 0 || len(registry.EventLogs) != 0) {
		t.Fatalf("step %d last watcher left registry %+v", step, registry)
	}
}
