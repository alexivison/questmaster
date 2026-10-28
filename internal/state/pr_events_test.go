package state

import (
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

func TestRecordPullRequestEventsMarksFilteredIDsSeen(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store := OpenStore(root)
	if err := store.Create(Manifest{SessionID: "qm-one"}); err != nil {
		t.Fatal(err)
	}
	pr, _ := ParsePullRequestRef("owner/repo#42")
	if _, err := WatchPullRequest(root, "qm-one", pr, time.Now().Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := RecordPullRequestEvents(root, pr.Key, nil, map[string]string{"comments": "own"}, "own"); err != nil {
		t.Fatal(err)
	}
	log, err := LoadPullRequestEventLog(root, pr.Key)
	if err != nil || !log.SeenIDs["own"] || log.LastIDs["comments"] != "own" || len(log.Events) != 0 {
		t.Fatalf("log=%+v err=%v", log, err)
	}
}
