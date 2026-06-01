package adapter

import (
	"os"
	"path/filepath"
	"testing"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return b
}

// TestPRStatusFromFixtures asserts PR() maps recorded GitHub responses to the
// correct CI/review vocabulary, with no network (Query is injected).
func TestPRStatusFromFixtures(t *testing.T) {
	cases := []struct {
		fixture    string
		wantNil    bool
		wantNumber int
		wantCI     string
		wantReview string
	}{
		{"pr_green_approved.json", false, 441, "green", "approved"},
		{"pr_pending_changes.json", false, 502, "pending", "changes"},
		{"pr_none.json", true, 0, "", ""},
	}
	for _, c := range cases {
		t.Run(c.fixture, func(t *testing.T) {
			data := fixture(t, c.fixture)
			src := &GitHubStatusSource{
				Query: func(repo, branch string) ([]byte, error) { return data, nil },
			}
			got, err := src.PR("acme/webapp", "feature")
			if err != nil {
				t.Fatalf("PR: %v", err)
			}
			if c.wantNil {
				if got != nil {
					t.Fatalf("PR = %#v, want nil (no PR)", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("PR = nil, want a status")
			}
			if got.Number != c.wantNumber {
				t.Errorf("Number = %d, want %d", got.Number, c.wantNumber)
			}
			if got.CI != c.wantCI {
				t.Errorf("CI = %q, want %q", got.CI, c.wantCI)
			}
			if got.Review != c.wantReview {
				t.Errorf("Review = %q, want %q", got.Review, c.wantReview)
			}
		})
	}
}

func TestPRStatusMissingRollupIsNone(t *testing.T) {
	raw := []byte(`{"data":{"repository":{"pullRequests":{"nodes":[{"number":7,"url":"u","reviewDecision":"APPROVED","commits":{"nodes":[{"commit":{"statusCheckRollup":null}}]}}]}}}}`)
	got, err := parsePRStatus(raw)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got.CI != "none" {
		t.Errorf("CI with null rollup = %q, want none", got.CI)
	}
}

func TestSplitRepo(t *testing.T) {
	if _, _, err := splitRepo("no-slash"); err == nil {
		t.Errorf("splitRepo accepted a repo with no owner/name")
	}
	owner, name, err := splitRepo("acme/webapp")
	if err != nil || owner != "acme" || name != "webapp" {
		t.Errorf("splitRepo(acme/webapp) = %q,%q,%v", owner, name, err)
	}
}
