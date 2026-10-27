package prstatus

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestFetchDetailsPaginatesToLastIDAndKeepsPendingReviewsOpen(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 27, 2, 0, 0, 0, time.UTC)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	pr.Watchers = []state.PullRequestWatcher{{SessionID: "qm-one", AddedAt: now.Add(-time.Hour).Format(time.RFC3339Nano)}}
	log := state.PullRequestEventLog{LastIDs: map[string]string{"comments": "old-comment", "reviews": "old-review", "review_comments": "old-line"}}
	queries := []string{}
	graph := func(_ context.Context, _, query string) ([]byte, []byte, error) {
		queries = append(queries, query)
		var source, nodes, page string
		switch {
		case strings.Contains(query, "comments(last:"):
			source = "comments"
			if strings.Contains(query, "before:") {
				nodes = `[{"id":"old-comment","body":"old","createdAt":"2026-10-27T00:01:00Z","author":{"login":"old"}}]`
				page = `false`
			} else {
				nodes = `[{"id":"new-comment","body":"hello","createdAt":"2026-10-27T01:05:00Z","author":{"login":"alice"}}]`
				page = `true`
			}
		case strings.Contains(query, "reviews(last:"):
			source = "reviews"
			nodes = `[{"id":"old-review","body":"old","submittedAt":"2026-10-27T00:01:00Z","state":"APPROVED"},{"id":"new-review","body":"fix","submittedAt":"2026-10-27T01:06:00Z","state":"CHANGES_REQUESTED","author":{"login":"bob"}},{"id":"pending-review","state":"PENDING"}]`
			page = `false`
		}
		return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-28T00:00:00Z"},"repository":{"pullRequest":{"%s":{"nodes":%s,"pageInfo":{"hasPreviousPage":%s,"startCursor":"cursor"}}}}}}`, source, nodes, page)), nil, nil
	}
	rest := func(_ context.Context, _, endpoint string) ([]byte, []byte, error) {
		if !strings.Contains(endpoint, "sort=created&direction=desc") {
			t.Fatalf("review comments must be sorted by creation: %s", endpoint)
		}
		return []byte(`[{"node_id":"new-line","body":"line","created_at":"2026-10-27T01:07:00Z","updated_at":"2026-10-27T01:07:00Z","user":{"login":"carol"}},{"node_id":"old-line","created_at":"2026-10-27T00:01:00Z","updated_at":"2026-10-27T00:01:00Z"}]`), nil, nil
	}
	events, ids, host := fetchDetails(context.Background(), pr, state.PullRequestStatus{}, state.PullRequestStatus{}, "", log, graph, rest, now)
	if host.Error != "" || len(events) != 3 || ids["reviews"] != "new-review" || ids["comments"] != "new-comment" || ids["review_comments"] != "new-line" || len(queries) != 3 {
		t.Fatalf("events=%#v ids=%#v host=%#v queries=%d", events, ids, host, len(queries))
	}
	if events[0].Kind != "comment" || events[1].Kind != "review" || events[2].Kind != "review_comment" || events[1].State != "changes_requested" {
		t.Fatalf("ordered events=%#v", events)
	}
}

func TestAlertCoalescesSanitizesAndFits(t *testing.T) {
	t.Parallel()
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	text := alertText(pr, []state.PullRequestEvent{
		{Kind: "comment"}, {Kind: "review_comment"},
		{Kind: "review", State: "changes_requested", Author: "evil\nrun: rm -rf /"},
		{Kind: "ci", Result: "failure"},
	})
	if len(text) > alertMaxBytes || strings.Contains(text, "\n") || strings.Contains(text, "rm -rf") || !strings.Contains(text, "2 comments") || !strings.Contains(text, "duplicates possible") || !strings.Contains(text, "questmaster pr events owner/repo#12 --unread") {
		t.Fatalf("alert %d bytes: %q", len(text), text)
	}
}

func TestAlertStillDeliversForLongRefs(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, host string
		fullRef    bool
	}{
		{"long GitHub ref", "github.com", true},
		{"oversize enterprise host", strings.Repeat("h", 180) + ".example", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			pr := state.PullRequest{Host: tc.host, Owner: strings.Repeat("o", 39), Repo: strings.Repeat("r", 100), Number: 12}
			text := alertText(pr, []state.PullRequestEvent{{Kind: "comment"}})
			if text == "" || len(text) > alertMaxBytes || !strings.Contains(text, "duplicates possible") || (strings.Contains(text, pr.Repo) != tc.fullRef) {
				t.Fatalf("long-ref alert %d bytes: %q", len(text), text)
			}
		})
	}
}

func TestFetchCICompletionUsesHeadCheckTime(t *testing.T) {
	t.Parallel()
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	now := time.Date(2026, 10, 27, 2, 0, 0, 0, time.UTC)
	run := func(_ context.Context, _, query string) ([]byte, []byte, error) {
		if !strings.Contains(query, "contexts(last:100)") {
			t.Fatalf("missing contexts query: %s", query)
		}
		return []byte(`{"data":{"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-28T00:00:00Z"},"repository":{"pullRequest":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","completedAt":"2026-10-27T01:00:00Z"},{"__typename":"StatusContext","updatedAt":"2026-10-27T01:30:00Z"}]}}}}]}}}}}`), nil, nil
	}
	at, problem := fetchCICompletion(context.Background(), pr, run, now)
	if problem.Error != "" || at != "2026-10-27T01:30:00Z" {
		t.Fatalf("CI completion = %q, %#v", at, problem)
	}
}

func TestInitialMergeAfterWatchBecomesEvent(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 27, 2, 0, 0, 0, time.UTC)
	pr, _ := state.ParsePullRequestRef("owner/repo#12")
	pr.Watchers = []state.PullRequestWatcher{{SessionID: "qm-one", AddedAt: now.Add(-time.Hour).Format(time.RFC3339Nano)}}
	graph := func(_ context.Context, _, query string) ([]byte, []byte, error) {
		source := "comments"
		if strings.Contains(query, "reviews(last:") {
			source = "reviews"
		}
		return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100},"repository":{"pullRequest":{"%s":{"nodes":[],"pageInfo":{"hasPreviousPage":false}}}}}}`, source)), nil, nil
	}
	rest := func(context.Context, string, string) ([]byte, []byte, error) { return []byte(`[]`), nil, nil }
	mergedAt := now.Add(-time.Minute).Format(time.RFC3339Nano)
	events, _, host := fetchDetails(context.Background(), pr, state.PullRequestStatus{}, state.PullRequestStatus{State: "merged"}, mergedAt, state.PullRequestEventLog{}, graph, rest, now)
	if host.Error != "" || len(events) != 1 || events[0].Kind != "state" || events[0].OccurredAt != mergedAt {
		t.Fatalf("merge event = %#v, %#v", events, host)
	}
}

func TestReopenEventUsesTimelineTimeForWatcherBaseline(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 27, 2, 0, 0, 0, time.UTC)
	reopenedAt := now.Add(-30 * time.Minute).Format(time.RFC3339Nano)
	for _, tc := range []struct {
		name  string
		added time.Time
		want  int
	}{
		{"before reopen", now.Add(-time.Hour), 1},
		{"after reopen", now.Add(-10 * time.Minute), 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			pr, _ := state.ParsePullRequestRef("owner/repo#12")
			pr.Watchers = []state.PullRequestWatcher{{SessionID: "qm-one", AddedAt: tc.added.Format(time.RFC3339Nano)}}
			graph := func(_ context.Context, _, query string) ([]byte, []byte, error) {
				source := "comments"
				if strings.Contains(query, "reviews(last:") {
					source = "reviews"
				}
				return []byte(fmt.Sprintf(`{"data":{"rateLimit":{"cost":1,"remaining":100},"repository":{"pullRequest":{"%s":{"nodes":[],"pageInfo":{"hasPreviousPage":false}},"timelineItems":{"nodes":[{"createdAt":%q}]}}}}}`, source, reopenedAt)), nil, nil
			}
			rest := func(context.Context, string, string) ([]byte, []byte, error) { return []byte(`[]`), nil, nil }
			events, _, host := fetchDetails(context.Background(), pr, state.PullRequestStatus{State: "closed", FetchedAt: now.Add(-time.Hour).Format(time.RFC3339Nano)}, state.PullRequestStatus{State: "open", UpdatedAt: now.Format(time.RFC3339Nano)}, "", state.PullRequestEventLog{}, graph, rest, now)
			if host.Error != "" || len(events) != tc.want {
				t.Fatalf("reopen events = %#v, %#v", events, host)
			}
		})
	}
}
