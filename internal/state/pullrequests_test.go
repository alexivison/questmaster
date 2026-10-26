package state

import (
	"os"
	"os/exec"
	"reflect"
	"strconv"
	"sync"
	"testing"
	"time"
)

func TestParsePullRequestRef(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct{ raw, key, owner, repo string }{
		{"Owner/Repo#42", "github.com/owner/repo#42", "Owner", "Repo"},
		{"https://GitHub.com/Owner/Repo/pull/042/files?x=1#discussion", "github.com/owner/repo#42", "Owner", "Repo"},
		{"https://ghe.example/Org/Service/pull/8", "ghe.example/org/service#8", "Org", "Service"},
		{"https://ghe.example:8443/Org/Service/pull/8", "ghe.example:8443/org/service#8", "Org", "Service"},
		{"owner/repo#0", "", "", ""},
		{"owner/repo#no", "", "", ""},
		{"http://github.com/o/r/pull/1", "", "", ""},
		{"https://github.com/o/r/issues/1", "", "", ""},
		{"https://github.com/o/r/pull/-1", "", "", ""},
		{"https://github.com/o/r/pull/1%2F2", "", "", ""},
		{"https://github.com/o/r/pull/1@evil", "", "", ""},
		{"x/y/z#1", "", "", ""},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			t.Parallel()
			got, err := ParsePullRequestRef(tc.raw)
			if tc.key == "" {
				if err == nil {
					t.Fatalf("accepted %q: %#v", tc.raw, got)
				}
				return
			}
			if err != nil || got.Key != tc.key || got.Owner != tc.owner || got.Repo != tc.repo {
				t.Fatalf("parse %q = %#v, %v", tc.raw, got, err)
			}
		})
	}
}

func TestPullRequestWatchLifecycle(t *testing.T) {
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
	ref, _ := ParsePullRequestRef("Owner/Repo#42")
	first := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	if added, err := WatchPullRequest(store.Root(), "qm-one", ref, first); err != nil || !added {
		t.Fatalf("watch: %v, %v", added, err)
	}
	if added, err := WatchPullRequest(store.Root(), "qm-one", ref, first.Add(time.Hour)); err != nil || added {
		t.Fatalf("idempotent watch: %v, %v", added, err)
	}
	if _, err := WatchPullRequest(store.Root(), "qm-two", ref, first); err != nil {
		t.Fatal(err)
	}
	prs, err := LivePullRequests(store, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(prs) != 1 || len(prs[0].Watchers) != 2 || prs[0].Watchers[0].AddedAt != first.Format(time.RFC3339Nano) {
		t.Fatalf("watches = %#v", prs)
	}
	if removed, err := UnwatchPullRequest(store.Root(), "qm-one", ref.Key); err != nil || !removed {
		t.Fatalf("unwatch: %v, %v", removed, err)
	}
	if removed, err := UnwatchPullRequest(store.Root(), "qm-one", ref.Key); err != nil || removed {
		t.Fatalf("repeat unwatch: %v, %v", removed, err)
	}
	if err := store.Delete("qm-two"); err != nil {
		t.Fatal(err)
	}
	if _, err := WatchPullRequest(store.Root(), "qm-two", ref, first); err == nil {
		t.Fatal("watch accepted deleted session")
	}
	prs, err = LivePullRequests(store, nil)
	if err != nil || len(prs) != 0 {
		t.Fatalf("dead watchers shown: %#v, %v", prs, err)
	}
	before, err := os.ReadFile(PullRequestsRegistryPath(store.Root()))
	if err != nil {
		t.Fatal(err)
	}
	if count, err := DropPullRequestWatches(store.Root(), func(id string) bool { return id == "qm-two" }, true); err != nil || count != 1 {
		t.Fatalf("dry-run: %d, %v", count, err)
	}
	after, err := os.ReadFile(PullRequestsRegistryPath(store.Root()))
	if err != nil || !reflect.DeepEqual(before, after) {
		t.Fatalf("dry-run wrote registry: %v", err)
	}
	if count, err := DropPullRequestWatches(store.Root(), func(id string) bool { return id == "qm-two" }, false); err != nil || count != 1 {
		t.Fatalf("drop: %d, %v", count, err)
	}
	prs, err = LoadPullRequests(store.Root())
	if err != nil || len(prs) != 0 {
		t.Fatalf("empty PR retained: %#v, %v", prs, err)
	}
}

func TestPullRequestConcurrentWatches(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	const workers = 12
	store, err := NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < workers; i++ {
		if err := store.Create(Manifest{SessionID: "qm-g" + strconv.Itoa(i)}); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 3; i++ {
		if err := store.Create(Manifest{SessionID: "qm-p" + strconv.Itoa(i)}); err != nil {
			t.Fatal(err)
		}
	}
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			ref, _ := ParsePullRequestRef("owner/repo#1")
			if _, err := WatchPullRequest(root, "qm-g"+strconv.Itoa(i), ref, time.Now()); err != nil {
				t.Error(err)
			}
		}(i)
	}
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			cmd := exec.Command(os.Args[0], "-test.run=^TestPullRequestWatchProcess$")
			cmd.Env = append(os.Environ(), "QM_PR_TEST_ROOT="+root, "QM_PR_TEST_ID=qm-p"+strconv.Itoa(i))
			if out, err := cmd.CombinedOutput(); err != nil {
				t.Errorf("process: %v: %s", err, out)
			}
		}(i)
	}
	wg.Wait()
	prs, err := LoadPullRequests(root)
	if err != nil || len(prs) != 1 || len(prs[0].Watchers) != workers+3 {
		t.Fatalf("lost writes: %#v, %v", prs, err)
	}
}

func TestPullRequestWatchProcess(t *testing.T) {
	root := os.Getenv("QM_PR_TEST_ROOT")
	if root == "" {
		return
	}
	ref, _ := ParsePullRequestRef("owner/repo#1")
	if _, err := WatchPullRequest(root, os.Getenv("QM_PR_TEST_ID"), ref, time.Now()); err != nil {
		t.Fatal(err)
	}
}
