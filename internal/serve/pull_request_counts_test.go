//go:build linux || darwin

package serve

import (
	"encoding/json"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestCountPullRequests(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		status *state.PullRequestStatus
		want   string
	}{
		{"missing", nil, `{}`},
		{"unknown", &state.PullRequestStatus{State: "unknown"}, `{}`},
		{"future state", &state.PullRequestStatus{State: "future", Draft: true}, `{}`},
		{"no state", &state.PullRequestStatus{Draft: true}, `{}`},
		{"inaccessible", &state.PullRequestStatus{State: "open", InaccessibleReason: "forbidden"}, `{}`},
		{"open", &state.PullRequestStatus{State: "open"}, `{"pull_request_counts":{"open":1}}`},
		{"draft", &state.PullRequestStatus{State: "open", Draft: true}, `{"pull_request_counts":{"draft":1}}`},
		{"merged", &state.PullRequestStatus{State: "merged", Draft: true}, `{"pull_request_counts":{"merged":1}}`},
		{"closed", &state.PullRequestStatus{State: "closed", Draft: true}, `{"pull_request_counts":{"closed":1}}`},
		{"stale known state", &state.PullRequestStatus{State: "open", Stale: true}, `{"pull_request_counts":{"open":1}}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			counts := countPullRequests([]state.PullRequest{{Status: tc.status}})
			got, err := json.Marshal(struct {
				Counts *PullRequestCounts `json:"pull_request_counts,omitempty"`
			}{counts})
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tc.want {
				t.Fatalf("counts = %s, want %s", got, tc.want)
			}
		})
	}
	if got := countPullRequests(nil); got != nil {
		t.Fatalf("empty watch set = %+v", got)
	}
	got := countPullRequests([]state.PullRequest{
		{Status: &state.PullRequestStatus{State: "open"}},
		{Status: &state.PullRequestStatus{State: "open"}},
		{Status: &state.PullRequestStatus{State: "open", Draft: true}},
		{Status: &state.PullRequestStatus{State: "merged"}},
		{Status: &state.PullRequestStatus{State: "closed"}},
	})
	if got == nil || *got != (PullRequestCounts{Open: 2, Draft: 1, Merged: 1, Closed: 1}) {
		t.Fatalf("combined counts = %+v", got)
	}
}
