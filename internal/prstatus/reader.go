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
}

type Result struct {
	Statuses map[string]state.PullRequestStatus `json:"-"`
	Hosts    map[string]HostResult              `json:"hosts"`
}

// Fetch groups by host and caps each GraphQL query at 50 PRs.
func Fetch(ctx context.Context, prs []state.PullRequest, run Runner, now time.Time) Result {
	result := Result{Statuses: map[string]state.PullRequestStatus{}, Hosts: map[string]HostResult{}}
	byHost := map[string][]state.PullRequest{}
	for _, pr := range prs {
		byHost[pr.Host] = append(byHost[pr.Host], pr)
	}
	for host, group := range byHost {
		var hostResult HostResult
		for start := 0; start < len(group); start += 50 {
			end := min(start+50, len(group))
			batch := group[start:end]
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
						result.Statuses[pr.Key] = repo.PullRequest.status(now)
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
				result.Statuses[pr.Key] = state.PullRequestStatus{InaccessibleReason: reason, FetchedAt: now.UTC().Format(time.RFC3339), Stale: false}
			}
			if hostResult.Error != "" {
				break
			}
			if hostResult.RateLimit != nil && hostResult.RateLimit.Remaining == 0 {
				hostResult.BackoffUntil = hostResult.RateLimit.ResetAt
				break
			}
		}
		if hostResult.Error != "" {
			for _, pr := range group {
				delete(result.Statuses, pr.Key)
			}
		}
		result.Hosts[host] = hostResult
	}
	return result
}

func query(prs []state.PullRequest) string {
	var b strings.Builder
	b.WriteString("query { rateLimit { cost remaining resetAt } ")
	// shortcut: review pagination stops at 100 reviewers per PR; paginate if a PR reaches that count.
	for i, pr := range prs {
		fmt.Fprintf(&b, "p%d: repository(owner:%s,name:%s) { pullRequest(number:%d) { title url state isDraft headRefOid updatedAt additions deletions totalCommentsCount reviewDecision latestOpinionatedReviews(last:100) { nodes { author { login } state submittedAt } } commits(last:1) { nodes { commit { statusCheckRollup { state } } } } } } ", i, strconv.Quote(pr.Owner), strconv.Quote(pr.Repo), pr.Number)
	}
	b.WriteByte('}')
	return b.String()
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
	Title          string  `json:"title"`
	URL            string  `json:"url"`
	State          string  `json:"state"`
	Draft          bool    `json:"isDraft"`
	HeadSHA        string  `json:"headRefOid"`
	UpdatedAt      string  `json:"updatedAt"`
	Additions      int     `json:"additions"`
	Deletions      int     `json:"deletions"`
	Comments       int     `json:"totalCommentsCount"`
	ReviewDecision *string `json:"reviewDecision"`
	Reviews        struct {
		Nodes []struct {
			Author struct {
				Login string `json:"login"`
			} `json:"author"`
			State       string `json:"state"`
			SubmittedAt string `json:"submittedAt"`
		} `json:"nodes"`
	} `json:"latestOpinionatedReviews"`
	Commits struct {
		Nodes []struct {
			Commit struct {
				Rollup *struct {
					State string `json:"state"`
				} `json:"statusCheckRollup"`
			} `json:"commit"`
		} `json:"nodes"`
	} `json:"commits"`
}

func (pr graphPR) status(now time.Time) state.PullRequestStatus {
	stateName := strings.ToLower(pr.State)
	review := "none"
	if pr.ReviewDecision != nil {
		review = reviewState(*pr.ReviewDecision)
	} else {
		latest := map[string]struct{ state, at string }{}
		for _, item := range pr.Reviews.Nodes {
			name := strings.ToLower(item.Author.Login)
			if name == "" || item.State == "DISMISSED" {
				continue
			}
			if item.SubmittedAt >= latest[name].at {
				latest[name] = struct{ state, at string }{item.State, item.SubmittedAt}
			}
		}
		for _, item := range latest {
			if item.state == "CHANGES_REQUESTED" {
				review = "changes_requested"
				break
			}
			if item.state == "APPROVED" {
				review = "approved"
			}
		}
	}
	ci := "none"
	if nodes := pr.Commits.Nodes; len(nodes) > 0 && nodes[len(nodes)-1].Commit.Rollup != nil {
		switch nodes[len(nodes)-1].Commit.Rollup.State {
		case "SUCCESS":
			ci = "success"
		case "FAILURE", "ERROR":
			ci = "failure"
		case "PENDING", "EXPECTED":
			ci = "pending"
		}
	}
	return state.PullRequestStatus{Title: pr.Title, URL: pr.URL, State: stateName, Draft: pr.Draft, HeadSHA: pr.HeadSHA, UpdatedAt: pr.UpdatedAt, Additions: pr.Additions, Deletions: pr.Deletions, Comments: pr.Comments, Review: review, CI: ci, FetchedAt: now.UTC().Format(time.RFC3339)}
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
	index := strings.LastIndex(text, separator)
	if index < 0 {
		separator = "\n\n"
		index = strings.LastIndex(text, separator)
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
