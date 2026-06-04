package gate

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"
)

type githubGateKind int

const (
	githubChecks githubGateKind = iota + 1
	githubReviewApproved
	githubPRMerged
)

type githubSpec struct {
	Kind   githubGateKind
	Target string
}

type githubPR struct {
	Number         int            `json:"number"`
	URL            string         `json:"url"`
	State          string         `json:"state"`
	MergedAt       string         `json:"mergedAt"`
	ReviewDecision string         `json:"reviewDecision"`
	Reviews        []githubReview `json:"reviews"`
}

type githubReview struct {
	State       string `json:"state"`
	SubmittedAt string `json:"submittedAt"`
	Author      struct {
		Login string `json:"login"`
	} `json:"author"`
}

type githubCheckRun struct {
	Name     string `json:"name"`
	Workflow string `json:"workflow"`
	Bucket   string `json:"bucket"`
	State    string `json:"state"`
}

func runGitHubCheck(r *Result, check, worktree string) {
	spec, err := parseGitHubSpec(check)
	if err != nil {
		r.Status = StatusError
		r.Output = err.Error()
		return
	}

	switch spec.Kind {
	case githubChecks:
		r.Status, r.Output = runGitHubChecks(spec, worktree)
	case githubReviewApproved:
		r.Status, r.Output = runGitHubReviewApproved(spec, worktree)
	case githubPRMerged:
		r.Status, r.Output = runGitHubPRMerged(spec, worktree)
	default:
		r.Status = StatusError
		r.Output = "unsupported GitHub check " + check + " (supported: " + supportedCheckGrammar + ")"
	}
}

func parseGitHubSpec(check string) (githubSpec, error) {
	rest, ok := strings.CutPrefix(check, "github:")
	if !ok {
		return githubSpec{}, fmt.Errorf("unsupported check %s (supported: %s)", check, supportedCheckGrammar)
	}
	op, target, hasTarget := strings.Cut(rest, ":")
	target = strings.TrimSpace(target)
	if hasTarget && target == "" {
		return githubSpec{}, fmt.Errorf("empty GitHub PR target in %s", check)
	}

	switch op {
	case "checks", "checks-green":
		return githubSpec{Kind: githubChecks, Target: target}, nil
	case "review-approved", "pr-approved":
		return githubSpec{Kind: githubReviewApproved, Target: target}, nil
	case "pr-merged", "merged":
		return githubSpec{Kind: githubPRMerged, Target: target}, nil
	default:
		return githubSpec{}, fmt.Errorf("unsupported GitHub check %s (supported: %s)", check, supportedCheckGrammar)
	}
}

func runGitHubChecks(spec githubSpec, worktree string) (Status, string) {
	pr, out := resolveGitHubPR(worktree, spec.Target, "number,url,state")
	if out != "" {
		return StatusError, out
	}

	target := spec.Target
	if target == "" {
		target = strconv.Itoa(pr.Number)
	}
	args := []string{"pr", "checks", target, "--json", "name,workflow,bucket,state"}
	stdout, stderr, err := runGH(worktree, args...)
	if strings.TrimSpace(stdout) == "" {
		if err != nil {
			return StatusError, "query GitHub checks: " + githubCommandError("gh pr checks", stderr, err)
		}
		return StatusError, fmt.Sprintf("github:checks returned empty JSON for PR #%d", pr.Number)
	}

	var checks []githubCheckRun
	if jsonErr := json.Unmarshal([]byte(stdout), &checks); jsonErr != nil {
		return StatusError, "parse gh pr checks JSON: " + jsonErr.Error()
	}
	if len(checks) == 0 {
		return StatusError, fmt.Sprintf("github:checks found no checks for PR #%d", pr.Number)
	}

	var passing, skipped int
	var failing, pending, unknown []string
	for _, c := range checks {
		switch normalizeCheckBucket(c) {
		case "pass":
			passing++
		case "skipping":
			skipped++
		case "fail", "cancel":
			failing = append(failing, checkLabel(c))
		case "pending":
			pending = append(pending, checkLabel(c))
		default:
			unknown = append(unknown, checkLabel(c))
		}
	}

	if len(pending) > 0 {
		return StatusError, fmt.Sprintf("github:checks pending for PR #%d: %s", pr.Number, joinLimited(pending, 5))
	}
	if len(unknown) > 0 {
		return StatusError, fmt.Sprintf("github:checks has unknown check state for PR #%d: %s", pr.Number, joinLimited(unknown, 5))
	}
	if len(failing) > 0 {
		return StatusFail, fmt.Sprintf("github:checks failed for PR #%d: %s", pr.Number, joinLimited(failing, 5))
	}

	message := fmt.Sprintf("PR #%d checks complete: %d passing", pr.Number, passing)
	if skipped > 0 {
		message += fmt.Sprintf(", %d skipped", skipped)
	}
	return StatusPass, message
}

func runGitHubReviewApproved(spec githubSpec, worktree string) (Status, string) {
	pr, out := resolveGitHubPR(worktree, spec.Target, "number,url,state,reviewDecision,reviews")
	if out != "" {
		return StatusError, out
	}
	return evaluateReviewApproved(pr)
}

func runGitHubPRMerged(spec githubSpec, worktree string) (Status, string) {
	pr, out := resolveGitHubPR(worktree, spec.Target, "number,url,state,mergedAt")
	if out != "" {
		return StatusError, out
	}
	if pr.MergedAt != "" || strings.EqualFold(pr.State, "MERGED") {
		when := strings.TrimSpace(pr.MergedAt)
		if when == "" {
			when = "reported by GitHub"
		}
		return StatusPass, fmt.Sprintf("PR #%d is merged (%s)", pr.Number, when)
	}
	state := strings.TrimSpace(pr.State)
	if state == "" {
		state = "unknown state"
	}
	return StatusFail, fmt.Sprintf("PR #%d is not merged (%s). This gate may be waiting on a human merge, not a code change.", pr.Number, state)
}

func resolveGitHubPR(worktree, target, fields string) (githubPR, string) {
	args := []string{"pr", "view"}
	if target != "" {
		args = append(args, target)
	}
	args = append(args, "--json", fields)
	stdout, stderr, err := runGH(worktree, args...)
	if err != nil {
		return githubPR{}, "resolve GitHub PR: " + githubCommandError("gh pr view", stderr, err)
	}
	if strings.TrimSpace(stdout) == "" {
		return githubPR{}, "resolve GitHub PR: gh pr view returned empty JSON"
	}

	var pr githubPR
	if jsonErr := json.Unmarshal([]byte(stdout), &pr); jsonErr != nil {
		return githubPR{}, "parse gh pr view JSON: " + jsonErr.Error()
	}
	if pr.Number == 0 {
		return githubPR{}, "parse gh pr view JSON: missing PR number"
	}
	return pr, ""
}

func runGH(worktree string, args ...string) (string, string, error) {
	cmd := exec.Command("gh", args...)
	cmd.Dir = worktree
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func githubCommandError(op, stderr string, err error) string {
	if errors.Is(err, exec.ErrNotFound) || strings.Contains(err.Error(), "executable file not found") {
		return "gh executable not found; install GitHub CLI and authenticate with `gh auth login`"
	}
	reason := strings.TrimSpace(stderr)
	if reason == "" {
		reason = err.Error()
	}
	return op + " failed: " + oneLine(reason)
}

func normalizeCheckBucket(c githubCheckRun) string {
	bucket := strings.ToLower(strings.TrimSpace(c.Bucket))
	switch bucket {
	case "pass", "fail", "pending", "skipping", "cancel":
		return bucket
	case "":
		return bucketFromState(c.State)
	default:
		return "unknown"
	}
}

func bucketFromState(state string) string {
	switch strings.ToUpper(strings.TrimSpace(state)) {
	case "SUCCESS", "PASSED":
		return "pass"
	case "SKIPPED", "NEUTRAL":
		return "skipping"
	case "FAILURE", "FAILED", "ERROR", "TIMED_OUT", "ACTION_REQUIRED":
		return "fail"
	case "CANCELLED", "CANCELED":
		return "cancel"
	case "PENDING", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED", "EXPECTED":
		return "pending"
	default:
		return "unknown"
	}
}

func checkLabel(c githubCheckRun) string {
	name := strings.TrimSpace(c.Name)
	if name == "" {
		name = "(unnamed check)"
	}
	if workflow := strings.TrimSpace(c.Workflow); workflow != "" && workflow != name {
		name = workflow + "/" + name
	}
	state := strings.TrimSpace(c.State)
	if state == "" {
		state = strings.TrimSpace(c.Bucket)
	}
	if state == "" {
		return name
	}
	return name + "=" + state
}

func evaluateReviewApproved(pr githubPR) (Status, string) {
	if decision := strings.ToUpper(strings.TrimSpace(pr.ReviewDecision)); decision != "" {
		switch decision {
		case "APPROVED":
			return StatusPass, fmt.Sprintf("PR #%d review decision is APPROVED", pr.Number)
		case "CHANGES_REQUESTED", "REVIEW_REQUIRED":
			return StatusFail, fmt.Sprintf("PR #%d review decision is %s", pr.Number, decision)
		default:
			return StatusFail, fmt.Sprintf("PR #%d review decision is %s, not APPROVED", pr.Number, decision)
		}
	}

	latestByAuthor := latestActiveReviewsByAuthor(pr.Reviews)
	if len(latestByAuthor) == 0 {
		return StatusFail, fmt.Sprintf("PR #%d has no approving review", pr.Number)
	}

	var approvers, blockers []string
	for _, r := range latestByAuthor {
		switch strings.ToUpper(strings.TrimSpace(r.State)) {
		case "APPROVED":
			approvers = append(approvers, reviewAuthor(r))
		case "CHANGES_REQUESTED":
			blockers = append(blockers, reviewAuthor(r))
		}
	}
	sort.Strings(approvers)
	sort.Strings(blockers)

	if len(blockers) > 0 {
		return StatusFail, fmt.Sprintf("PR #%d has changes requested by %s", pr.Number, strings.Join(blockers, ", "))
	}
	if len(approvers) > 0 {
		return StatusPass, fmt.Sprintf("PR #%d approved by %s", pr.Number, strings.Join(approvers, ", "))
	}
	return StatusFail, fmt.Sprintf("PR #%d has no approving review", pr.Number)
}

func latestActiveReviewsByAuthor(in []githubReview) map[string]githubReview {
	reviews := activeReviews(in)
	latest := make(map[string]githubReview, len(reviews))
	for _, r := range reviews {
		latest[reviewAuthor(r)] = r
	}
	return latest
}

func activeReviews(in []githubReview) []githubReview {
	reviews := make([]githubReview, 0, len(in))
	for _, r := range in {
		switch strings.ToUpper(strings.TrimSpace(r.State)) {
		case "APPROVED", "CHANGES_REQUESTED":
			reviews = append(reviews, r)
		}
	}
	sort.SliceStable(reviews, func(i, j int) bool {
		ti, iOK := parseReviewTime(reviews[i].SubmittedAt)
		tj, jOK := parseReviewTime(reviews[j].SubmittedAt)
		if iOK && jOK {
			return ti.Before(tj)
		}
		return false
	})
	return reviews
}

func parseReviewTime(raw string) (time.Time, bool) {
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(raw))
	return t, err == nil
}

func reviewAuthor(r githubReview) string {
	if login := strings.TrimSpace(r.Author.Login); login != "" {
		return login
	}
	return "unknown reviewer"
}

func joinLimited(items []string, max int) string {
	if len(items) <= max {
		return strings.Join(items, ", ")
	}
	return strings.Join(items[:max], ", ") + fmt.Sprintf(", and %d more", len(items)-max)
}

func oneLine(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len([]rune(s)) <= 240 {
		return s
	}
	return string([]rune(s)[:240]) + "..."
}
