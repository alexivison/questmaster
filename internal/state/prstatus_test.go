package state

import (
	"os"
	"testing"
	"time"
)

func TestPullRequestStatusPersistence(t *testing.T) {
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
	one, _ := ParsePullRequestRef("o/r#1")
	two, _ := ParsePullRequestRef("o/r#2")
	for _, item := range []struct {
		id string
		pr PullRequest
	}{{"qm-one", one}, {"qm-two", two}} {
		if _, err := WatchPullRequest(store.Root(), item.id, item.pr, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	first := PullRequestStatus{Title: "first", FetchedAt: "2026-01-01T00:00:00Z"}
	if err := SavePullRequestStatuses(store.Root(), map[string]PullRequestStatus{one.Key: first, two.Key: {Title: "second"}}, nil); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(PullRequestStatusPath(store.Root()))
	if err != nil {
		t.Fatal(err)
	}
	first.FetchedAt = "2026-01-02T00:00:00Z"
	if err := SavePullRequestStatuses(store.Root(), map[string]PullRequestStatus{one.Key: first, two.Key: {Title: "second"}}, nil); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(PullRequestStatusPath(store.Root()))
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("unchanged status rewrote file")
	}
	if err := SavePullRequestStatuses(store.Root(), nil, map[string]bool{"github.com": true}); err != nil {
		t.Fatal(err)
	}
	statuses, err := LoadPullRequestStatuses(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	if !statuses[one.Key].Stale || statuses[one.Key].Title != "first" || statuses[one.Key].FetchedAt != "2026-01-01T00:00:00Z" {
		t.Fatalf("last good status lost: %#v", statuses[one.Key])
	}
	if _, err := UnwatchPullRequest(store.Root(), "qm-two", two.Key); err != nil {
		t.Fatal(err)
	}
	if err := SavePullRequestStatuses(store.Root(), nil, nil); err != nil {
		t.Fatal(err)
	}
	statuses, err = LoadPullRequestStatuses(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := statuses[two.Key]; ok {
		t.Fatal("unwatched status kept")
	}
}
