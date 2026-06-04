package gate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunCheckPass(t *testing.T) {
	r := RunCheck("tests", "cmd:true", t.TempDir())
	if r.Status != StatusPass {
		t.Errorf("exit 0 → %q, want pass", r.Status)
	}
}

func TestRunCheckFailWithOutput(t *testing.T) {
	r := RunCheck("tests", "cmd:echo boom; exit 1", t.TempDir())
	if r.Status != StatusFail {
		t.Errorf("nonzero with output → %q, want fail", r.Status)
	}
	if !strings.Contains(r.Output, "boom") {
		t.Errorf("output not captured: %q", r.Output)
	}
	if r.Misconfigured() {
		t.Errorf("a real failure must not read as misconfigured")
	}
}

func TestRunCheckMissingCommandIsError(t *testing.T) {
	r := RunCheck("tests", "cmd:definitely-not-a-real-command-xyz", t.TempDir())
	if r.Status != StatusError {
		t.Errorf("missing command → %q, want error (misconfigured)", r.Status)
	}
	if !r.Misconfigured() {
		t.Errorf("a command-not-found must read as misconfigured, not fail")
	}
}

func TestRunCheckUnsupportedTypeIsError(t *testing.T) {
	for _, check := range []string{"github:unknown", "typecheck", "lint", "coverage:80"} {
		r := RunCheck("g", check, t.TempDir())
		if r.Status != StatusError {
			t.Errorf("check %q → %q, want unsupported-check error", check, r.Status)
		}
	}
}

func TestRunCheckRunsInWorktree(t *testing.T) {
	dir := t.TempDir()
	r := RunCheck("pwd", "cmd:pwd", dir)
	if r.Status != StatusPass {
		t.Fatalf("pwd → %q, want pass", r.Status)
	}
	// macOS /tmp is a symlink to /private/tmp; compare resolved paths.
	wantResolved, _ := filepath.EvalSymlinks(dir)
	gotResolved, _ := filepath.EvalSymlinks(strings.TrimSpace(r.Output))
	if gotResolved != wantResolved {
		t.Errorf("ran in %q, want worktree %q", strings.TrimSpace(r.Output), dir)
	}
}

func TestRunCheckCreatesNoFiles(t *testing.T) {
	dir := t.TempDir()
	_ = RunCheck("noop", "cmd:true", dir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("runner created files in the worktree: %v", entries)
	}
}

func TestRunCheckGitHubChecksPass(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
	t.Setenv("GH_CHECKS_STDOUT", `[
		{"name":"test","workflow":"ci","bucket":"pass","state":"SUCCESS"},
		{"name":"lint","workflow":"ci","bucket":"skipping","state":"SKIPPED"}
	]`)

	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusPass {
		t.Fatalf("github checks → %q, want pass; output:\n%s", r.Status, r.Output)
	}
	for _, want := range []string{"PR #42", "1 passing", "1 skipped"} {
		if !strings.Contains(r.Output, want) {
			t.Fatalf("github checks pass output missing %q:\n%s", want, r.Output)
		}
	}
}

func TestRunCheckGitHubChecksFail(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
	t.Setenv("GH_CHECKS_STDOUT", `[
		{"name":"test","workflow":"ci","bucket":"fail","state":"FAILURE"},
		{"name":"deploy","workflow":"release","bucket":"cancel","state":"CANCELLED"}
	]`)
	t.Setenv("GH_CHECKS_EXIT", "1")

	r := RunCheck("ci", "github:checks-green", t.TempDir())
	if r.Status != StatusFail {
		t.Fatalf("github failed checks → %q, want fail; output:\n%s", r.Status, r.Output)
	}
	for _, want := range []string{"test", "FAILURE", "deploy", "CANCELLED"} {
		if !strings.Contains(r.Output, want) {
			t.Fatalf("github checks fail output missing %q:\n%s", want, r.Output)
		}
	}
}

func TestRunCheckGitHubChecksPendingIsError(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
	t.Setenv("GH_CHECKS_STDOUT", `[{"name":"test","workflow":"ci","bucket":"pending","state":"IN_PROGRESS"}]`)
	t.Setenv("GH_CHECKS_EXIT", "8")

	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusError {
		t.Fatalf("pending github checks → %q, want error; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "pending") || !strings.Contains(r.Output, "test") {
		t.Fatalf("pending output should name the pending check:\n%s", r.Output)
	}
}

func TestRunCheckGitHubChecksErrorsWhenNoPR(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDERR", "no pull requests found for branch")
	t.Setenv("GH_VIEW_EXIT", "1")

	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusError {
		t.Fatalf("github checks without a PR → %q, want error; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "resolve GitHub PR") || !strings.Contains(r.Output, "no pull requests") {
		t.Fatalf("no-PR output should explain PR resolution failure:\n%s", r.Output)
	}
}

func TestRunCheckGitHubAuthFailureIsError(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDERR", "HTTP 401: Bad credentials")
	t.Setenv("GH_VIEW_EXIT", "1")

	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusError {
		t.Fatalf("github auth failure → %q, want error; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "Bad credentials") {
		t.Fatalf("auth failure output should surface gh stderr:\n%s", r.Output)
	}
}

func TestRunCheckGitHubChecksErrorsOnMalformedJSON(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
	t.Setenv("GH_CHECKS_STDOUT", `{not-json`)

	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusError {
		t.Fatalf("malformed github checks JSON → %q, want error; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "parse gh pr checks JSON") {
		t.Fatalf("malformed output should name JSON parsing:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewApprovedPasses(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviews":[
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer"}},
			{"state":"APPROVED","submittedAt":"2026-06-01T11:00:00Z","author":{"login":"reviewer"}}
		]
	}`)

	r := RunCheck("review", "github:review-approved", t.TempDir())
	if r.Status != StatusPass {
		t.Fatalf("approved review → %q, want pass; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "approved by reviewer") {
		t.Fatalf("approval output should name reviewer:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewDecisionChangesRequestedOverridesLaterApproval(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviewDecision":"CHANGES_REQUESTED",
		"reviews":[
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer-a"}},
			{"state":"APPROVED","submittedAt":"2026-06-01T11:00:00Z","author":{"login":"reviewer-b"}}
		]
	}`)

	r := RunCheck("review", "github:review-approved", t.TempDir())
	if r.Status != StatusFail {
		t.Fatalf("reviewDecision changes requested → %q, want fail; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "review decision is CHANGES_REQUESTED") {
		t.Fatalf("reviewDecision failure should name GitHub decision:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewDecisionApprovedOverridesAwkwardHistory(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviewDecision":"APPROVED",
		"reviews":[
			{"state":"APPROVED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer-a"}},
			{"state":"DISMISSED","submittedAt":"2026-06-01T11:00:00Z","author":{"login":"reviewer-a"}},
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T12:00:00Z","author":{"login":"reviewer-b"}}
		]
	}`)

	r := RunCheck("review", "github:review-approved", t.TempDir())
	if r.Status != StatusPass {
		t.Fatalf("reviewDecision approved → %q, want pass; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "review decision is APPROVED") {
		t.Fatalf("approval output should name GitHub decision:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewFallbackUsesLatestStatePerAuthor(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviews":[
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer-a"}},
			{"state":"APPROVED","submittedAt":"2026-06-01T11:00:00Z","author":{"login":"reviewer-a"}},
			{"state":"APPROVED","submittedAt":"2026-06-01T12:00:00Z","author":{"login":"reviewer-b"}},
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T13:00:00Z","author":{"login":"reviewer-b"}},
			{"state":"APPROVED","submittedAt":"2026-06-01T14:00:00Z","author":{"login":"reviewer-c"}},
			{"state":"DISMISSED","submittedAt":"2026-06-01T15:00:00Z","author":{"login":"reviewer-c"}}
		]
	}`)

	r := RunCheck("review", "github:review-approved", t.TempDir())
	if r.Status != StatusFail {
		t.Fatalf("fallback latest per author → %q, want fail; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "changes requested by reviewer-b") {
		t.Fatalf("fallback should block on reviewer-b's latest active review:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewChangesRequestedFails(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviews":[
			{"state":"APPROVED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer"}},
			{"state":"CHANGES_REQUESTED","submittedAt":"2026-06-01T11:00:00Z","author":{"login":"reviewer"}}
		]
	}`)

	r := RunCheck("review", "github:pr-approved", t.TempDir())
	if r.Status != StatusFail {
		t.Fatalf("later changes-requested review → %q, want fail; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "changes requested") {
		t.Fatalf("changes-requested output should be clear:\n%s", r.Output)
	}
}

func TestRunCheckGitHubReviewNoApprovalFails(t *testing.T) {
	installFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{
		"number":42,
		"url":"https://github.com/acme/app/pull/42",
		"state":"OPEN",
		"reviews":[{"state":"COMMENTED","submittedAt":"2026-06-01T10:00:00Z","author":{"login":"reviewer"}}]
	}`)

	r := RunCheck("review", "github:review-approved", t.TempDir())
	if r.Status != StatusFail {
		t.Fatalf("review without approval → %q, want fail; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "no approving review") {
		t.Fatalf("no-approval output should be clear:\n%s", r.Output)
	}
}

func TestRunCheckGitHubMergedPassAndOpenFail(t *testing.T) {
	tests := map[string]struct {
		check      string
		viewJSON   string
		wantStatus Status
		wantOutput string
	}{
		"merged": {
			check:      "github:pr-merged",
			viewJSON:   `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"MERGED","mergedAt":"2026-06-01T12:00:00Z"}`,
			wantStatus: StatusPass,
			wantOutput: "merged",
		},
		"open": {
			check:      "github:merged",
			viewJSON:   `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`,
			wantStatus: StatusFail,
			wantOutput: "not merged",
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			installFakeGH(t)
			t.Setenv("GH_VIEW_STDOUT", tc.viewJSON)

			r := RunCheck("merged", tc.check, t.TempDir())
			if r.Status != tc.wantStatus {
				t.Fatalf("%s → %q, want %q; output:\n%s", tc.check, r.Status, tc.wantStatus, r.Output)
			}
			if !strings.Contains(r.Output, tc.wantOutput) {
				t.Fatalf("output missing %q:\n%s", tc.wantOutput, r.Output)
			}
		})
	}
}

func TestRunCheckGitHubExplicitTargetSuffix(t *testing.T) {
	tests := map[string]string{
		"number": "42",
		"url":    "https://github.com/acme/app/pull/42",
	}
	for name, target := range tests {
		t.Run(name, func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "gh-args.log")
			installFakeGH(t)
			t.Setenv("GH_ARGS_LOG", logPath)
			t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
			t.Setenv("GH_CHECKS_STDOUT", `[{"name":"test","workflow":"ci","bucket":"pass","state":"SUCCESS"}]`)

			r := RunCheck("ci", "github:checks:"+target, t.TempDir())
			if r.Status != StatusPass {
				t.Fatalf("explicit target checks → %q, want pass; output:\n%s", r.Status, r.Output)
			}
			raw, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatalf("read fake gh args log: %v", err)
			}
			log := string(raw)
			if !strings.Contains(log, "pr view "+target+" --json") || !strings.Contains(log, "pr checks "+target+" --json") {
				t.Fatalf("explicit PR target was not passed to gh commands:\n%s", log)
			}
		})
	}
}

func TestRunCheckGitHubMissingGHIsError(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	r := RunCheck("ci", "github:checks", t.TempDir())
	if r.Status != StatusError {
		t.Fatalf("missing gh → %q, want error; output:\n%s", r.Status, r.Output)
	}
	if !strings.Contains(r.Output, "gh executable not found") {
		t.Fatalf("missing-gh output should be clear:\n%s", r.Output)
	}
}

func installFakeGH(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	path := filepath.Join(bin, "gh")
	script := `#!/bin/sh
if [ -n "$GH_ARGS_LOG" ]; then
  printf '%s\n' "$*" >> "$GH_ARGS_LOG"
fi

if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  if [ -n "$GH_VIEW_STDERR" ]; then
    printf '%s\n' "$GH_VIEW_STDERR" >&2
  fi
  if [ -n "$GH_VIEW_STDOUT" ]; then
    printf '%s\n' "$GH_VIEW_STDOUT"
  fi
  exit ${GH_VIEW_EXIT:-0}
fi

if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  if [ -n "$GH_CHECKS_STDERR" ]; then
    printf '%s\n' "$GH_CHECKS_STDERR" >&2
  fi
  if [ -n "$GH_CHECKS_STDOUT" ]; then
    printf '%s\n' "$GH_CHECKS_STDOUT"
  fi
  exit ${GH_CHECKS_EXIT:-0}
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 99
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake gh: %v", err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}
