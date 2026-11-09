// Package prstatus reads watched pull-request summaries from GitHub GraphQL.
package prstatus

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

type Runner func(context.Context, string, string) ([]byte, []byte, error)

func GH(ctx context.Context, host, query string) ([]byte, []byte, error) {
	cmd := exec.CommandContext(ctx, "gh", "api", "graphql", "--hostname", host, "--include", "-f", "query="+query)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.Output()
	return stdout, stderr.Bytes(), err
}

type RateLimit struct {
	Cost      int    `json:"cost"` // total cost across this host's batches
	Remaining int    `json:"remaining"`
	ResetAt   string `json:"reset_at"`
}

type HostResult struct {
	RateLimit    *RateLimit `json:"rate_limit,omitempty"`
	Error        string     `json:"error,omitempty"`
	BackoffUntil string     `json:"backoff_until,omitempty"`
	CheckedAt    string     `json:"checked_at,omitempty"`
}

type Result struct {
	Statuses map[string]state.PullRequestStatus `json:"-"`
	StateAt  map[string]string                  `json:"-"`
	Viewers  map[string]string                  `json:"-"`
	Hosts    map[string]HostResult              `json:"hosts"`
}

// Fetch groups by host and caps each GraphQL query at 50 PRs.
func Fetch(ctx context.Context, prs []state.PullRequest, run Runner, now time.Time) Result {
	result := Result{Statuses: map[string]state.PullRequestStatus{}, StateAt: map[string]string{}, Viewers: map[string]string{}, Hosts: map[string]HostResult{}}
	byHost := map[string][]state.PullRequest{}
	for _, pr := range prs {
		byHost[pr.Host] = append(byHost[pr.Host], pr)
	}
	for host, group := range byHost {
		var hostResult HostResult
		for start := 0; start < len(group); start += 50 {
			end := min(start+50, len(group))
			batch := group[start:end]
			hostResult.CheckedAt = now.UTC().Format(time.RFC3339)
			stdout, stderr, runErr := run(ctx, host, query(batch))
			body, retryAfter, headerReset := responseBody(stdout)
			var response graphResponse
			decodeErr := json.Unmarshal(body, &response)
			if decodeErr == nil && response.Data.RateLimit != nil {
				if hostResult.RateLimit == nil {
					hostResult.RateLimit = &RateLimit{}
				}
				hostResult.RateLimit.Cost += response.Data.RateLimit.Cost
				hostResult.RateLimit.Remaining = response.Data.RateLimit.Remaining
				hostResult.RateLimit.ResetAt = response.Data.RateLimit.ResetAt
			}
			if headerReset != "" {
				if hostResult.RateLimit == nil {
					hostResult.RateLimit = &RateLimit{}
				}
				hostResult.RateLimit.Remaining = 0
				hostResult.RateLimit.ResetAt = headerReset
			}
			message := strings.TrimSpace(string(stderr))
			if message == "" {
				message = response.Message
			}
			if message == "" && len(response.Errors) > 0 {
				message = response.Errors[0].Message
			}
			if message == "" && runErr != nil {
				message = runErr.Error()
			}
			if decodeErr != nil || response.Data.Aliases == nil {
				hostResult.Error = message
				if hostResult.Error == "" {
					hostResult.Error = "invalid GitHub response"
				}
				hostResult.BackoffUntil = backoff(now, retryAfter, hostResult.RateLimit, message)
				break
			}
			if isWholeRequestError(response.Errors, message) {
				hostResult.Error = message
				if hostResult.Error == "" {
					hostResult.Error = response.Errors[0].Message
				}
				hostResult.BackoffUntil = backoff(now, retryAfter, hostResult.RateLimit, hostResult.Error)
				break
			}
			var viewer struct {
				Login string `json:"login"`
			}
			if json.Unmarshal(response.Data.Aliases["viewer"], &viewer) == nil && viewer.Login != "" {
				result.Viewers[host] = viewer.Login
			}
			for i, pr := range batch {
				alias := fmt.Sprintf("p%d", i)
				raw, exists := response.Data.Aliases[alias]
				if !exists {
					hostResult.Error = "incomplete GitHub response"
					break
				}
				if len(raw) > 0 && string(raw) != "null" {
					var repo struct {
						PullRequest *graphPR `json:"pullRequest"`
					}
					if err := json.Unmarshal(raw, &repo); err != nil {
						hostResult.Error = "invalid GitHub PR data"
						break
					}
					if repo.PullRequest != nil {
						result.Statuses[pr.Key] = repo.PullRequest.status(now, result.Viewers[host])
						switch repo.PullRequest.State {
						case "MERGED":
							result.StateAt[pr.Key] = repo.PullRequest.MergedAt
						case "CLOSED":
							result.StateAt[pr.Key] = repo.PullRequest.ClosedAt
						}
						continue
					}
				}
				reason := "not_found"
				for _, problem := range response.Errors {
					if len(problem.Path) > 0 && problem.Path[0] == alias {
						if strings.Contains(strings.ToLower(problem.Message), "saml") {
							reason = "saml"
						} else if problem.Type == "FORBIDDEN" {
							reason = "forbidden"
						}
						break
					}
				}
				result.Statuses[pr.Key] = state.PullRequestStatus{InaccessibleReason: reason, ChangedAt: now.UTC().Format(time.RFC3339), Stale: false}
			}
			if hostResult.Error != "" {
				break
			}
			if hostResult.RateLimit != nil && hostResult.RateLimit.Remaining == 0 {
				hostResult.BackoffUntil = hostResult.RateLimit.ResetAt
				break
			}
		}
		result.Hosts[host] = hostResult
	}
	return result
}

func query(prs []state.PullRequest) string {
	var b strings.Builder
	b.WriteString("query { rateLimit { cost remaining resetAt } viewer { login } ")
	// shortcut: review connections stop at 100 reviewers per PR; paginate if a PR reaches that count.
	// latestReviews is each reviewer's latest review of any state; latestOpinionatedReviews keeps an approval that a later comment would hide.
	for i, pr := range prs {
		fmt.Fprintf(&b, "p%d: repository(owner:%s,name:%s) { pullRequest(number:%d) { title url state closedAt mergedAt isDraft headRefOid updatedAt additions deletions totalCommentsCount reviewDecision author { login __typename } latestOpinionatedReviews(last:100) { nodes { state } } latestReviews(last:100) { nodes { state author { login __typename } } } commits(last:1) { nodes { commit { statusCheckRollup { state %s } } } } } } ", i, strconv.Quote(pr.Owner), strconv.Quote(pr.Repo), pr.Number, ciContextsQuery)
	}
	b.WriteByte('}')
	return b.String()
}

// checkHead re-reads only the PR head when a pending alert contains CI.
func checkHead(ctx context.Context, pr state.PullRequest, run Runner, now time.Time) (string, HostResult) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	query := fmt.Sprintf("query { rateLimit { cost remaining resetAt } p0: repository(owner:%s,name:%s) { pullRequest(number:%d) { headRefOid } } }", strconv.Quote(pr.Owner), strconv.Quote(pr.Repo), pr.Number)
	stdout, stderr, runErr := run(ctx, pr.Host, query)
	body, retry, reset := responseBody(stdout)
	var response graphResponse
	decodeErr := json.Unmarshal(body, &response)
	rate := response.Data.RateLimit
	if reset != "" {
		rate = &RateLimit{Remaining: 0, ResetAt: reset}
	}
	message := strings.TrimSpace(string(stderr))
	if message == "" {
		message = response.Message
	}
	if message == "" && len(response.Errors) > 0 {
		message = response.Errors[0].Message
	}
	if runErr != nil || decodeErr != nil || isWholeRequestError(response.Errors, message) {
		result := detailFailure(now, retry, reset, rate, []byte(message), runErr)
		result.RateLimit = rate
		return "", result
	}
	var alias struct {
		PullRequest *struct {
			HeadSHA string `json:"headRefOid"`
		} `json:"pullRequest"`
	}
	if err := json.Unmarshal(response.Data.Aliases["p0"], &alias); err != nil || alias.PullRequest == nil || alias.PullRequest.HeadSHA == "" {
		return "", HostResult{Error: "invalid GitHub head response", RateLimit: rate, BackoffUntil: backoff(now, retry, rate, message)}
	}
	return alias.PullRequest.HeadSHA, HostResult{RateLimit: rate, BackoffUntil: backoff(now, retry, rate, message)}
}

type graphError struct {
	Type    string   `json:"type"`
	Path    []string `json:"path"`
	Message string   `json:"message"`
}

type graphResponse struct {
	Data struct {
		RateLimit *RateLimit                 `json:"rateLimit"`
		Aliases   map[string]json.RawMessage `json:"-"`
	} `json:"data"`
	Errors  []graphError `json:"errors"`
	Message string       `json:"message"`
}

func (r *graphResponse) UnmarshalJSON(data []byte) error {
	var raw struct {
		Data    map[string]json.RawMessage `json:"data"`
		Errors  []graphError               `json:"errors"`
		Message string                     `json:"message"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	r.Errors = raw.Errors
	r.Message = raw.Message
	r.Data.Aliases = raw.Data
	if value := raw.Data["rateLimit"]; len(value) > 0 {
		var rate struct {
			Cost      int    `json:"cost"`
			Remaining int    `json:"remaining"`
			ResetAt   string `json:"resetAt"`
		}
		if json.Unmarshal(value, &rate) == nil {
			r.Data.RateLimit = &RateLimit{rate.Cost, rate.Remaining, rate.ResetAt}
		}
	}
	return nil
}

type graphPR struct {
	Title          string       `json:"title"`
	URL            string       `json:"url"`
	State          string       `json:"state"`
	ClosedAt       string       `json:"closedAt"`
	MergedAt       string       `json:"mergedAt"`
	Draft          bool         `json:"isDraft"`
	HeadSHA        string       `json:"headRefOid"`
	UpdatedAt      string       `json:"updatedAt"`
	Additions      int          `json:"additions"`
	Deletions      int          `json:"deletions"`
	Comments       int          `json:"totalCommentsCount"`
	ReviewDecision *string      `json:"reviewDecision"`
	Author         graphActor   `json:"author"`
	Reviews        graphReviews `json:"latestOpinionatedReviews"`
	LatestReviews  graphReviews `json:"latestReviews"`
	Commits        struct {
		Nodes []struct {
			Commit struct {
				Rollup *struct {
					State    string `json:"state"`
					Contexts struct {
						Nodes []ciContext `json:"nodes"`
					} `json:"contexts"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"commits"`
}

// graphActor is a GitHub login. Bots have TypeName "Bot", which decides their [bot] suffix.
type graphActor struct {
	Login    string `json:"login"`
	TypeName string `json:"__typename"`
}

// login is the actor's login in the form the event log uses.
func (actor graphActor) login() string {
	return normalizeBotLogin(actor.Login, actor.TypeName == "Bot")
}

type graphReview struct {
	State  string     `json:"state"`
	Author graphActor `json:"author"`
}

type graphReviews struct {
	Nodes []graphReview `json:"nodes"`
}

// ciContextsQuery selects what dates the head commit's checks: a check run's finish, a commit status's last update.
// ponytail: the newest 100 contexts cover ordinary PRs; paginate if a head SHA grows beyond 100 checks.
const ciContextsQuery = "contexts(last:100) { nodes { __typename ... on CheckRun { completedAt } ... on StatusContext { state updatedAt } } }"

type ciContext struct {
	CompletedAt string `json:"completedAt"` // check runs; null until they finish
	State       string `json:"state"`       // commit statuses
	UpdatedAt   string `json:"updatedAt"`   // commit statuses
}

// ciCompletion returns when the newest check finished, and whether any check has not finished.
func ciCompletion(contexts []ciContext) (string, bool) {
	var latest time.Time
	running := false
	for _, check := range contexts {
		at := check.CompletedAt
		if at == "" && check.State != "PENDING" && check.State != "EXPECTED" {
			at = check.UpdatedAt
		}
		if at == "" {
			running = true // a check run without a finish time, or a commit status still pending
			continue
		}
		if t, err := time.Parse(time.RFC3339Nano, at); err == nil && t.After(latest) {
			latest = t
		}
	}
	if latest.IsZero() {
		return "", running
	}
	return latest.UTC().Format(time.RFC3339Nano), running
}

func (pr graphPR) status(now time.Time, viewer string) state.PullRequestStatus {
	stateName := strings.ToLower(pr.State)
	review := pr.review(viewer)
	ci := "none"
	completedAt, running := "", false
	if nodes := pr.Commits.Nodes; len(nodes) > 0 && nodes[len(nodes)-1].Commit.Rollup != nil {
		rollup := nodes[len(nodes)-1].Commit.Rollup
		switch rollup.State {
		case "SUCCESS":
			ci = "success"
		case "FAILURE", "ERROR":
			ci = "failure"
		case "PENDING", "EXPECTED":
			ci = "pending"
		}
		if ci == "success" || ci == "failure" {
			completedAt, running = ciCompletion(rollup.Contexts.Nodes)
		}
	}
	return state.PullRequestStatus{Title: pr.Title, URL: pr.URL, Author: pr.authorFor(viewer), State: stateName, Draft: pr.Draft, HeadSHA: pr.HeadSHA, UpdatedAt: pr.UpdatedAt, Additions: pr.Additions, Deletions: pr.Deletions, Comments: pr.Comments, Review: review, CI: ci, CICompletedAt: completedAt, CIRunning: running, ChangedAt: now.UTC().Format(time.RFC3339)}
}

// review is the PR's review state. A comment shows only where GitHub gives no approval or changes request.
func (pr graphPR) review(viewer string) string {
	decided := pr.decidedReview()
	if decided == "approved" || decided == "changes_requested" {
		return decided
	}
	if pr.commentedByOthers(viewer) {
		return "commented"
	}
	return decided
}

// decidedReview is GitHub's review decision, or the opinionated reviews when there is no decision.
func (pr graphPR) decidedReview() string {
	if pr.ReviewDecision != nil {
		return reviewState(*pr.ReviewDecision)
	}
	review := "none"
	for _, item := range pr.Reviews.Nodes {
		if item.State == "CHANGES_REQUESTED" {
			return "changes_requested"
		}
		if item.State == "APPROVED" {
			review = "approved"
		}
	}
	return review
}

// commentedByOthers reports whether a reviewer's latest review is a comment from someone other than the PR author
// or the viewer. Authors reply to threads through COMMENTED reviews, and the viewer's own discussion stays out of status.
func (pr graphPR) commentedByOthers(viewer string) bool {
	author := pr.Author.login()
	for _, item := range pr.LatestReviews.Nodes {
		if item.State != "COMMENTED" {
			continue
		}
		reviewer := item.Author.login()
		if !sameLogin(reviewer, author) && !sameLogin(reviewer, viewer) {
			return true
		}
	}
	return false
}

// authorFor is the PR author's login, or empty when the viewer wrote the PR. An unknown viewer keeps the login.
func (pr graphPR) authorFor(viewer string) string {
	author := pr.Author.login()
	if sameLogin(author, viewer) {
		return ""
	}
	return author
}

// sameLogin compares GitHub logins case-insensitively; an empty login matches nothing.
func sameLogin(a, b string) bool {
	return a != "" && strings.EqualFold(a, b)
}

func reviewState(value string) string {
	switch value {
	case "APPROVED":
		return "approved"
	case "CHANGES_REQUESTED":
		return "changes_requested"
	case "REVIEW_REQUIRED":
		return "review_required"
	default:
		return "none"
	}
}

func responseBody(stdout []byte) ([]byte, string, string) {
	text := string(stdout)
	separator := "\r\n\r\n"
	index := strings.Index(text, separator)
	if lf := strings.Index(text, "\n\n"); lf >= 0 && (index < 0 || lf < index) {
		separator = "\n\n"
		index = lf
	}
	if index < 0 {
		return stdout, "", ""
	}
	header := strings.ToLower(text[:index])
	retry := ""
	reset := ""
	remaining := ""
	for _, line := range strings.Split(header, "\n") {
		if strings.HasPrefix(line, "retry-after:") {
			retry = strings.TrimSpace(strings.TrimPrefix(line, "retry-after:"))
		}
		if strings.HasPrefix(line, "x-ratelimit-reset:") {
			reset = strings.TrimSpace(strings.TrimPrefix(line, "x-ratelimit-reset:"))
		}
		if strings.HasPrefix(line, "x-ratelimit-remaining:") {
			remaining = strings.TrimSpace(strings.TrimPrefix(line, "x-ratelimit-remaining:"))
		}
	}
	if remaining == "0" {
		if unix, err := strconv.ParseInt(reset, 10, 64); err == nil {
			reset = time.Unix(unix, 0).UTC().Format(time.RFC3339)
		}
	} else {
		reset = ""
	}
	return []byte(text[index+len(separator):]), retry, reset
}

func isWholeRequestError(errors []graphError, stderr string) bool {
	if strings.Contains(strings.ToLower(stderr), "secondary rate limit") || strings.Contains(strings.ToLower(stderr), "rate limit exceeded") {
		return true
	}
	for _, problem := range errors {
		if len(problem.Path) == 0 {
			return true
		}
	}
	return false
}

func backoff(now time.Time, retryAfter string, rate *RateLimit, message string) string {
	if seconds, err := strconv.Atoi(retryAfter); err == nil && seconds > 0 {
		return now.Add(time.Duration(seconds) * time.Second).UTC().Format(time.RFC3339)
	}
	if rate != nil && rate.Remaining == 0 {
		return rate.ResetAt
	}
	if strings.Contains(strings.ToLower(message), "secondary rate limit") {
		return now.Add(time.Minute).UTC().Format(time.RFC3339)
	}
	return ""
}
