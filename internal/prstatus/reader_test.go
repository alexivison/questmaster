package prstatus

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func pr(t *testing.T, ref string) state.PullRequest {
	t.Helper()
	value, err := state.ParsePullRequestRef(ref)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func TestFetchViewerLoginPerHost(t *testing.T) {
	t.Parallel()
	prs := []state.PullRequest{pr(t, "owner/repo#1"), pr(t, "https://enterprise.example/owner/repo/pull/2")}
	run := func(_ context.Context, host, query string) ([]byte, []byte, error) {
		if !strings.Contains(query, "viewer { login }") {
			t.Fatalf("viewer omitted from %s query: %s", host, query)
		}
		login := "alice"
		if host == "enterprise.example" {
			login = "bob"
		}
		return []byte(fmt.Sprintf(`{"data":{"viewer":{"login":%q},"p0":{"pullRequest":{"title":"PR","state":"OPEN"}}}}`, login)), nil, nil
	}
	got := Fetch(context.Background(), prs, run, time.Now())
	if got.Viewers["github.com"] != "alice" || got.Viewers["enterprise.example"] != "bob" {
		t.Fatalf("viewers=%v", got.Viewers)
	}
	missing := Fetch(context.Background(), prs[:1], func(context.Context, string, string) ([]byte, []byte, error) {
		return []byte(`{"data":{"p0":{"pullRequest":{"title":"PR","state":"OPEN"}}}}`), nil, nil
	}, time.Now())
	if missing.Viewers["github.com"] != "" || len(missing.Statuses) != 1 {
		t.Fatalf("missing viewer result=%+v", missing)
	}
}

func TestFetchKeepsStatusWhenViewerFieldFails(t *testing.T) {
	t.Parallel()
	pr := pr(t, "owner/repo#1")
	got := Fetch(context.Background(), []state.PullRequest{pr}, func(context.Context, string, string) ([]byte, []byte, error) {
		return []byte(`{"data":{"viewer":null,"p0":{"pullRequest":{"title":"PR","state":"OPEN"}}},"errors":[{"path":["viewer"],"message":"viewer unavailable"}]}`), nil, nil
	}, time.Now())
	if got.Hosts["github.com"].Error != "" || got.Statuses[pr.Key].Title != "PR" || got.Viewers["github.com"] != "" {
		t.Fatalf("viewer field error lost PR status or enabled filtering: %+v", got)
	}
}

func TestFetchBatchesReposAndHosts(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	prs := []state.PullRequest{pr(t, "one/repo#1"), pr(t, "two/other#2")}
	for i := 3; i <= 51; i++ {
		prs = append(prs, pr(t, fmt.Sprintf("one/repo#%d", i)))
	}
	prs = append(prs, pr(t, "https://enterprise.example/one/repo/pull/1"))
	var calls []string
	run := func(_ context.Context, host, query string) ([]byte, []byte, error) {
		calls = append(calls, host+":"+query)
		if host == "enterprise.example" {
			return nil, []byte("gh: authentication required"), errors.New("exit 1")
		}
		if strings.Count(query, ": repository(") > 50 {
			t.Fatal("batch exceeded 50")
		}
		if strings.Contains(query, "number:1)") && !strings.Contains(query, "owner:\"two\",name:\"other\"") {
			t.Fatal("mixed repo omitted")
		}
		data := map[string]any{"rateLimit": map[string]any{"cost": 1, "remaining": 400, "resetAt": "2026-10-26T01:00:00Z"}}
		for i := 0; i < strings.Count(query, ": repository("); i++ {
			data[fmt.Sprintf("p%d", i)] = map[string]any{"pullRequest": map[string]any{"title": "hello", "state": "OPEN", "latestOpinionatedReviews": map[string]any{"nodes": []any{}}}}
		}
		body, _ := json.Marshal(map[string]any{"data": data})
		return append([]byte("HTTP/2.0 200 OK\r\n\r\n"), body...), nil, nil
	}
	got := Fetch(context.Background(), prs, run, now)
	if len(calls) != 3 || len(got.Statuses) != 51 || got.Hosts["enterprise.example"].Error == "" {
		t.Fatalf("calls=%d statuses=%d hosts=%#v", len(calls), len(got.Statuses), got.Hosts)
	}
	if got.Hosts["github.com"].RateLimit.Cost != 2 {
		t.Fatal("rate limit missing")
	}
	for _, host := range []string{"github.com", "enterprise.example"} {
		if got.Hosts[host].CheckedAt != now.Format(time.RFC3339) {
			t.Fatalf("%s checked_at = %q", host, got.Hosts[host].CheckedAt)
		}
	}
}

func TestResponseBodyKeepsBlankLinesInJSON(t *testing.T) {
	t.Parallel()
	for _, newline := range []string{"\n", "\r\n"} {
		body := "{" + newline + newline + "  \"data\": {\"rateLimit\": {\"cost\": 1}}" + newline + "}"
		got, _, _ := responseBody([]byte("HTTP/2.0 200 OK" + newline + "Retry-After: 30" + newline + newline + body))
		if string(got) != body {
			t.Fatalf("body = %q", got)
		}
	}
	body := "{\r\n\r\n  \"data\": {}\r\n}"
	got, _, _ := responseBody([]byte("HTTP/2.0 200 OK\n\n" + body))
	if string(got) != body {
		t.Fatalf("mixed newline body = %q", got)
	}
}

func TestLaterBatchFailureKeepsFreshEarlierStatuses(t *testing.T) {
	t.Parallel()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-reader"}); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	prs := make([]state.PullRequest, 0, 51)
	for n := 1; n <= 51; n++ {
		ref := pr(t, fmt.Sprintf("o/r#%d", n))
		if _, err := state.WatchPullRequest(store.Root(), "qm-reader", ref, now); err != nil {
			t.Fatal(err)
		}
		prs = append(prs, ref)
	}
	if err := state.SavePullRequestStatuses(store.Root(), map[string]state.PullRequestStatus{prs[50].Key: {Title: "last good", ChangedAt: "2026-10-25T00:00:00Z"}}, nil); err != nil {
		t.Fatal(err)
	}
	run := func(_ context.Context, _ string, query string) ([]byte, []byte, error) {
		if strings.Contains(query, "number:51)") {
			return nil, []byte("gh: network unavailable"), errors.New("exit 1")
		}
		data := map[string]any{"rateLimit": map[string]any{"cost": 1, "remaining": 400, "resetAt": "2026-10-26T01:00:00Z"}}
		for i := 0; i < 50; i++ {
			data[fmt.Sprintf("p%d", i)] = map[string]any{"pullRequest": map[string]any{"title": "fresh", "state": "OPEN"}}
		}
		body, _ := json.Marshal(map[string]any{"data": data})
		return body, nil, nil
	}
	result := Fetch(context.Background(), prs, run, now)
	if len(result.Statuses) != 50 || result.Hosts["github.com"].Error == "" {
		t.Fatalf("statuses=%d host=%#v", len(result.Statuses), result.Hosts["github.com"])
	}
	if err := state.SavePullRequestStatuses(store.Root(), result.Statuses, map[string]bool{"github.com": true}); err != nil {
		t.Fatal(err)
	}
	statuses, err := state.LoadPullRequestStatuses(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	if statuses[prs[0].Key].Title != "fresh" || statuses[prs[0].Key].Stale {
		t.Fatalf("first status=%#v", statuses[prs[0].Key])
	}
	if statuses[prs[50].Key].Title != "last good" || !statuses[prs[50].Key].Stale {
		t.Fatalf("last status=%#v", statuses[prs[50].Key])
	}
}

func TestFetchKeepsPartialDataAndClassifiesErrors(t *testing.T) {
	t.Parallel()
	prs := []state.PullRequest{pr(t, "o/r#1"), pr(t, "o/r#2"), pr(t, "o/r#3"), pr(t, "o/r#4")}
	response := `{"data":{"rateLimit":{"cost":1,"remaining":100,"resetAt":"2026-10-26T01:00:00Z"},"p0":{"pullRequest":{"title":"good","state":"OPEN"}},"p1":{"pullRequest":null},"p2":null,"p3":null},"errors":[{"type":"NOT_FOUND","path":["p1","pullRequest"],"message":"missing"},{"type":"FORBIDDEN","path":["p2"],"message":"denied"},{"type":"NOT_FOUND","path":["p3"],"message":"SAML SSO required"}]}`
	got := Fetch(context.Background(), prs, func(context.Context, string, string) ([]byte, []byte, error) {
		return []byte(response), []byte("gh: partial error"), errors.New("exit 1")
	}, time.Now())
	for i, want := range []string{"", "not_found", "forbidden", "saml"} {
		if value := got.Statuses[prs[i].Key].InaccessibleReason; value != want {
			t.Fatalf("PR %d reason=%q want %q", i, value, want)
		}
	}
	if got.Statuses[prs[0].Key].Title != "good" || got.Hosts["github.com"].Error != "" {
		t.Fatalf("partial data lost: %#v", got)
	}
}

func TestStatusReviewAndCI(t *testing.T) {
	t.Parallel()
	tests := []struct{ name, decision, reviews, rollup, wantReview, wantCI string }{
		{"null", "null", `[]`, "null", "none", "none"},
		{"approve", "null", `[{"state":"APPROVED"}]`, `{"state":"SUCCESS"}`, "approved", "success"},
		{"same reviewer latest approval", "null", `[{"state":"APPROVED"}]`, `{"state":"FAILURE"}`, "approved", "failure"},
		{"disagree", "null", `[{"state":"APPROVED"},{"state":"CHANGES_REQUESTED"}]`, `{"state":"ERROR"}`, "changes_requested", "failure"},
		{"dismissed", "null", `[{"state":"DISMISSED"}]`, `{"state":"EXPECTED"}`, "none", "pending"},
		{"decision", `"REVIEW_REQUIRED"`, `[{"state":"APPROVED"}]`, `{"state":"PENDING"}`, "review_required", "pending"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var node graphPR
			data := fmt.Sprintf(`{"reviewDecision":%s,"latestOpinionatedReviews":{"nodes":%s},"commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}`, tc.decision, tc.reviews, tc.rollup)
			if err := json.Unmarshal([]byte(data), &node); err != nil {
				t.Fatal(err)
			}
			got := node.status(time.Now(), "")
			if got.Review != tc.wantReview || got.CI != tc.wantCI {
				t.Fatalf("review=%q CI=%q", got.Review, got.CI)
			}
		})
	}
}

func TestStatusCIDatesTheNewestFinishedCheck(t *testing.T) {
	t.Parallel()
	const (
		checkDone    = `{"__typename":"CheckRun","completedAt":"2026-10-27T01:00:00Z"}`
		checkRunning = `{"__typename":"CheckRun","completedAt":null}`
	)
	tests := []struct {
		name, rollup, wantAt string
		wantRunning          bool
	}{
		{"finished check", `{"state":"SUCCESS","contexts":{"nodes":[` + checkDone + `]}}`, "2026-10-27T01:00:00Z", false},
		{"newest of a check run and a commit status", `{"state":"SUCCESS","contexts":{"nodes":[` + checkDone + `,{"__typename":"StatusContext","state":"SUCCESS","updatedAt":"2026-10-27T01:30:00Z"}]}}`, "2026-10-27T01:30:00Z", false},
		{"failure while a check run still runs", `{"state":"FAILURE","contexts":{"nodes":[` + checkDone + `,` + checkRunning + `]}}`, "2026-10-27T01:00:00Z", true},
		{"a pending commit status is not a finish", `{"state":"FAILURE","contexts":{"nodes":[` + checkDone + `,{"__typename":"StatusContext","state":"PENDING","updatedAt":"2026-10-27T02:00:00Z"}]}}`, "2026-10-27T01:00:00Z", true},
		{"pending rollup carries neither", `{"state":"PENDING","contexts":{"nodes":[` + checkDone + `,` + checkRunning + `]}}`, "", false},
		{"no contexts", `{"state":"SUCCESS"}`, "", false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var node graphPR
			if err := json.Unmarshal([]byte(fmt.Sprintf(`{"commits":{"nodes":[{"commit":{"statusCheckRollup":%s}}]}}`, tc.rollup)), &node); err != nil {
				t.Fatal(err)
			}
			got := node.status(time.Now(), "")
			if got.CICompletedAt != tc.wantAt || got.CIRunning != tc.wantRunning {
				t.Fatalf("CICompletedAt=%q CIRunning=%v, want %q %v", got.CICompletedAt, got.CIRunning, tc.wantAt, tc.wantRunning)
			}
		})
	}
}

func TestStatusReviewPrecedence(t *testing.T) {
	t.Parallel()
	const (
		noReviews           = `[]`
		approvalOpinion     = `[{"state":"APPROVED"}]`
		changesOpinion      = `[{"state":"CHANGES_REQUESTED"}]`
		reviewerComment     = `[{"state":"COMMENTED","author":{"login":"reviewer-one","__typename":"User"}}]`
		authorComment       = `[{"state":"COMMENTED","author":{"login":"example-author","__typename":"User"}}]`
		authorCommentCase   = `[{"state":"COMMENTED","author":{"login":"EXAMPLE-AUTHOR","__typename":"User"}}]`
		viewerComment       = `[{"state":"COMMENTED","author":{"login":"example-viewer","__typename":"User"}}]`
		viewerCommentCase   = `[{"state":"COMMENTED","author":{"login":"Example-Viewer","__typename":"User"}}]`
		botComment          = `[{"state":"COMMENTED","author":{"login":"review-bot","__typename":"Bot"}}]`
		dismissedByReviewer = `[{"state":"DISMISSED","author":{"login":"reviewer-one","__typename":"User"}}]`
	)
	tests := []struct {
		name, decision, opinionated, latest, viewer, want string
	}{
		{"comment without a decision", "null", noReviews, reviewerComment, "example-viewer", "commented"},
		{"comment beside review required", `"REVIEW_REQUIRED"`, noReviews, reviewerComment, "example-viewer", "commented"},
		{"bot commenter counts", "null", noReviews, botComment, "example-viewer", "commented"},
		{"unknown viewer leaves the viewer's comment counting", "null", noReviews, viewerComment, "", "commented"},
		{"approved decision beats comment", `"APPROVED"`, noReviews, reviewerComment, "example-viewer", "approved"},
		{"changes requested decision beats comment", `"CHANGES_REQUESTED"`, noReviews, reviewerComment, "example-viewer", "changes_requested"},
		{"approval without a decision beats comment", "null", approvalOpinion, reviewerComment, "example-viewer", "approved"},
		{"changes requested without a decision beats comment", "null", changesOpinion, reviewerComment, "example-viewer", "changes_requested"},
		{"review required without a comment", `"REVIEW_REQUIRED"`, noReviews, noReviews, "example-viewer", "review_required"},
		{"no review at all", "null", noReviews, noReviews, "example-viewer", "none"},
		{"dismissed review is not a comment", "null", noReviews, dismissedByReviewer, "example-viewer", "none"},
		{"author's comment is ignored", `"REVIEW_REQUIRED"`, noReviews, authorComment, "example-viewer", "review_required"},
		{"author's comment is ignored in any case", "null", noReviews, authorCommentCase, "example-viewer", "none"},
		{"viewer's comment is ignored", "null", noReviews, viewerComment, "example-viewer", "none"},
		{"viewer's comment is ignored in any case", "null", noReviews, viewerCommentCase, "example-viewer", "none"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var node graphPR
			data := fmt.Sprintf(`{"author":{"login":"example-author","__typename":"User"},"reviewDecision":%s,"latestOpinionatedReviews":{"nodes":%s},"latestReviews":{"nodes":%s}}`, tc.decision, tc.opinionated, tc.latest)
			if err := json.Unmarshal([]byte(data), &node); err != nil {
				t.Fatal(err)
			}
			if got := node.status(time.Now(), tc.viewer).Review; got != tc.want {
				t.Fatalf("review=%q, want %q", got, tc.want)
			}
		})
	}
}

// TestStatusCommentEndsWhenReviewerIsRequestedAgain walks a PR through the review lifecycle: a reviewer asked again
// after commenting is waiting on the author, so the comment stops counting until they review again.
func TestStatusCommentEndsWhenReviewerIsRequestedAgain(t *testing.T) {
	t.Parallel()
	const (
		noOpinions               = `[]`
		approvalOpinion          = `[{"state":"APPROVED"}]`
		changesOpinion           = `[{"state":"CHANGES_REQUESTED"}]`
		noComments               = `[]`
		commentOne               = `[{"state":"COMMENTED","author":{"login":"reviewer-one","__typename":"User"}}]`
		commentOneCase           = `[{"state":"COMMENTED","author":{"login":"Reviewer-One","__typename":"User"}}]`
		commentTwo               = `[{"state":"COMMENTED","author":{"login":"reviewer-two","__typename":"User"}}]`
		commentOneAndTwo         = `[{"state":"COMMENTED","author":{"login":"reviewer-one","__typename":"User"}},{"state":"COMMENTED","author":{"login":"reviewer-two","__typename":"User"}}]`
		commentBot               = `[{"state":"COMMENTED","author":{"login":"review-bot","__typename":"Bot"}}]`
		commentBotSuffix         = `[{"state":"COMMENTED","author":{"login":"review-bot[bot]","__typename":"Bot"}}]`
		approvalOne              = `[{"state":"APPROVED","author":{"login":"reviewer-one","__typename":"User"}}]`
		changesOne               = `[{"state":"CHANGES_REQUESTED","author":{"login":"reviewer-one","__typename":"User"}}]`
		approvalOneAndCommentTwo = `[{"state":"APPROVED","author":{"login":"reviewer-one","__typename":"User"}},{"state":"COMMENTED","author":{"login":"reviewer-two","__typename":"User"}}]`
		changesOneAndCommentTwo  = `[{"state":"CHANGES_REQUESTED","author":{"login":"reviewer-one","__typename":"User"}},{"state":"COMMENTED","author":{"login":"reviewer-two","__typename":"User"}}]`
		noRequests               = `[]`
		requestOne               = `[{"requestedReviewer":{"__typename":"User","login":"reviewer-one"}}]`
		requestOneCase           = `[{"requestedReviewer":{"__typename":"User","login":"REVIEWER-ONE"}}]`
		requestTwo               = `[{"requestedReviewer":{"__typename":"User","login":"reviewer-two"}}]`
		requestTeam              = `[{"requestedReviewer":{"__typename":"Team","login":"reviewer-one"}}]`
		requestNullNodes         = `[{"requestedReviewer":null},{"requestedReviewer":{"__typename":"Mannequin"}}]`
		requestBot               = `[{"requestedReviewer":{"__typename":"Bot","login":"review-bot"}}]`
		requestBotSuffix         = `[{"requestedReviewer":{"__typename":"Bot","login":"review-bot[bot]"}}]`
	)
	tests := []struct {
		name, decision, opinionated, latest, requested, want string
	}{
		{"requested before any review", `"REVIEW_REQUIRED"`, noOpinions, noComments, requestOne, "review_required"},
		{"commented and not requested", `"REVIEW_REQUIRED"`, noOpinions, commentOne, noRequests, "commented"},
		{"commented then requested again", `"REVIEW_REQUIRED"`, noOpinions, commentOne, requestOne, "review_required"},
		{"commented then requested again without a decision", "null", noOpinions, commentOne, requestOne, "none"},
		{"approved after the request", `"APPROVED"`, approvalOpinion, approvalOne, noRequests, "approved"},
		{"comments again after the request", `"REVIEW_REQUIRED"`, noOpinions, commentOne, noRequests, "commented"},
		{"changes requested after the request", `"CHANGES_REQUESTED"`, changesOpinion, changesOne, noRequests, "changes_requested"},
		{"one commenter requested again, the other not", `"REVIEW_REQUIRED"`, noOpinions, commentOneAndTwo, requestTwo, "commented"},
		{"a request for someone who did not comment", `"REVIEW_REQUIRED"`, noOpinions, commentOne, requestTwo, "commented"},
		{"a team request does not hide a user's comment", `"REVIEW_REQUIRED"`, noOpinions, commentOne, requestTeam, "commented"},
		{"null and non-account request nodes do not hide a comment", `"REVIEW_REQUIRED"`, noOpinions, commentOne, requestNullNodes, "commented"},
		{"request in another letter case hides the comment", `"REVIEW_REQUIRED"`, noOpinions, commentOneCase, requestOneCase, "review_required"},
		{"bot request with the suffix matches a comment without it", `"REVIEW_REQUIRED"`, noOpinions, commentBot, requestBotSuffix, "review_required"},
		{"bot request without the suffix matches a comment with it", `"REVIEW_REQUIRED"`, noOpinions, commentBotSuffix, requestBot, "review_required"},
		// An approval or changes request is a decision: a re-request or another reviewer's comment does not change it.
		{"approved decision stays approved when the approver is requested again", `"APPROVED"`, approvalOpinion, approvalOne, requestOne, "approved"},
		{"approval without a decision stays approved when the approver is requested again", "null", approvalOpinion, approvalOne, requestOne, "approved"},
		{"changes requested decision stays when the reviewer is requested again", `"CHANGES_REQUESTED"`, changesOpinion, changesOne, requestOne, "changes_requested"},
		{"changes requested without a decision stays when the reviewer is requested again", "null", changesOpinion, changesOne, requestOne, "changes_requested"},
		{"approved stays approved beside a comment from a requested reviewer", `"APPROVED"`, approvalOpinion, approvalOneAndCommentTwo, requestTwo, "approved"},
		{"approved stays approved beside a comment from an unrequested reviewer", `"APPROVED"`, approvalOpinion, approvalOneAndCommentTwo, noRequests, "approved"},
		{"approval without a decision stays approved beside a comment", "null", approvalOpinion, approvalOneAndCommentTwo, noRequests, "approved"},
		{"changes requested stays beside a comment from a requested reviewer", `"CHANGES_REQUESTED"`, changesOpinion, changesOneAndCommentTwo, requestTwo, "changes_requested"},
		{"changes requested stays beside a comment from an unrequested reviewer", `"CHANGES_REQUESTED"`, changesOpinion, changesOneAndCommentTwo, noRequests, "changes_requested"},
		{"changes requested without a decision stays beside a comment", "null", changesOpinion, changesOneAndCommentTwo, noRequests, "changes_requested"},
		// GitHub's REVIEW_REQUIRED decision decides even when one reviewer has approved (a partial approval).
		{"review required decision ignores an opinionated approval", `"REVIEW_REQUIRED"`, approvalOpinion, approvalOne, noRequests, "review_required"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var node graphPR
			data := fmt.Sprintf(`{"author":{"login":"example-author","__typename":"User"},"reviewDecision":%s,"latestOpinionatedReviews":{"nodes":%s},"latestReviews":{"nodes":%s},"reviewRequests":{"nodes":%s}}`, tc.decision, tc.opinionated, tc.latest, tc.requested)
			if err := json.Unmarshal([]byte(data), &node); err != nil {
				t.Fatal(err)
			}
			if got := node.status(time.Now(), "example-viewer").Review; got != tc.want {
				t.Fatalf("review=%q, want %q", got, tc.want)
			}
		})
	}
}

func TestStatusAuthorIsSetOnlyWhenNotViewer(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name, author, viewer, want string
	}{
		{"viewer's own PR", `{"login":"example-author","__typename":"User"}`, "example-author", ""},
		{"viewer's own PR in another case", `{"login":"EXAMPLE-Author","__typename":"User"}`, "example-author", ""},
		{"someone else's PR", `{"login":"example-author","__typename":"User"}`, "reviewer-one", "example-author"},
		{"unknown viewer keeps the author", `{"login":"example-author","__typename":"User"}`, "", "example-author"},
		{"bot author carries its suffix", `{"login":"release-bot","__typename":"Bot"}`, "reviewer-one", "release-bot[bot]"},
		{"missing author", `null`, "reviewer-one", ""},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			var node graphPR
			if err := json.Unmarshal([]byte(`{"author":`+tc.author+`}`), &node); err != nil {
				t.Fatal(err)
			}
			if got := node.status(time.Now(), tc.viewer).Author; got != tc.want {
				t.Fatalf("author=%q, want %q", got, tc.want)
			}
		})
	}
}

func TestFetchReadsAuthorAndCommentedReview(t *testing.T) {
	t.Parallel()
	pr := pr(t, "owner/repo#1")
	run := func(_ context.Context, _, query string) ([]byte, []byte, error) {
		for _, field := range []string{
			"latestOpinionatedReviews(last:100) { nodes { state } }",
			"latestReviews(last:100) { nodes { state author { login __typename } } }",
			"reviewRequests(first:100) { nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } } } }",
		} {
			if !strings.Contains(query, field) {
				t.Fatalf("query omits %q: %s", field, query)
			}
		}
		return []byte(`{"data":{"viewer":{"login":"reviewer-one"},"p0":{"pullRequest":{"title":"PR","state":"OPEN","author":{"login":"example-author","__typename":"User"},"reviewDecision":null,"latestOpinionatedReviews":{"nodes":[]},"latestReviews":{"nodes":[{"state":"COMMENTED","author":{"login":"review-bot","__typename":"Bot"}}]},"reviewRequests":{"nodes":[{"requestedReviewer":null},{"requestedReviewer":{"__typename":"Team"}}]},"commits":{"nodes":[]}}}}}`), nil, nil
	}
	got := Fetch(context.Background(), []state.PullRequest{pr}, run, time.Now()).Statuses[pr.Key]
	if got.Review != "commented" || got.Author != "example-author" {
		t.Fatalf("review=%q author=%q", got.Review, got.Author)
	}
}

func TestRateLimitBackoff(t *testing.T) {
	t.Parallel()
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	pr := pr(t, "o/r#1")
	for _, tc := range []struct{ name, stdout, stderr, want string }{
		{"primary", `{"data":{"rateLimit":{"cost":1,"remaining":0,"resetAt":"2026-10-26T01:00:00Z"}},"errors":[{"message":"API rate limit exceeded"}]}`, "gh: API rate limit exceeded", "2026-10-26T01:00:00Z"},
		{"primary header", "HTTP/2.0 200 OK\r\nX-RateLimit-Remaining: 0\r\nX-RateLimit-Reset: 1792976400\r\n\r\n{\"errors\":[{\"message\":\"API rate limit exceeded\"}]}", "gh: API rate limit exceeded", "2026-10-26T01:00:00Z"},
		{"secondary", "HTTP/2.0 403 Forbidden\r\nRetry-After: 120\r\n\r\n{\"message\":\"secondary rate limit\"}", "gh: secondary rate limit", "2026-10-26T00:02:00Z"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := Fetch(context.Background(), []state.PullRequest{pr}, func(context.Context, string, string) ([]byte, []byte, error) {
				return []byte(tc.stdout), []byte(tc.stderr), errors.New("exit 1")
			}, now)
			if host := got.Hosts["github.com"]; host.BackoffUntil != tc.want || host.Error == "" {
				t.Fatalf("host=%#v", host)
			}
		})
	}
}
