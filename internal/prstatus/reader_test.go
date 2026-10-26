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
		{"approve", "null", `[{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2026-01-01"}]`, `{"state":"SUCCESS"}`, "approved", "success"},
		{"same reviewer", "null", `[{"author":{"login":"a"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-01"},{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2026-01-02"}]`, `{"state":"FAILURE"}`, "approved", "failure"},
		{"disagree", "null", `[{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2026-01-01"},{"author":{"login":"b"},"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02"}]`, `{"state":"ERROR"}`, "changes_requested", "failure"},
		{"dismissed", "null", `[{"author":{"login":"a"},"state":"DISMISSED","submittedAt":"2026-01-01"}]`, `{"state":"EXPECTED"}`, "none", "pending"},
		{"decision", `"REVIEW_REQUIRED"`, `[{"author":{"login":"a"},"state":"APPROVED","submittedAt":"2026-01-01"}]`, `{"state":"PENDING"}`, "review_required", "pending"},
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
