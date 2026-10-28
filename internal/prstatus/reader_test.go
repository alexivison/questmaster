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
			got := node.status(time.Now())
			if got.Review != tc.wantReview || got.CI != tc.wantCI {
				t.Fatalf("review=%q CI=%q", got.Review, got.CI)
			}
		})
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
