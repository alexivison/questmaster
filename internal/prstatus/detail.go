package prstatus

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func GHREST(ctx context.Context, host, endpoint string) ([]byte, []byte, error) {
	cmd := exec.CommandContext(ctx, "gh", "api", endpoint, "--hostname", host, "--include")
	stdout, err := cmd.Output()
	if exit, ok := err.(*exec.ExitError); ok {
		return stdout, exit.Stderr, err
	}
	return stdout, nil, err
}

type detailNode struct {
	ID          string `json:"id"`
	Body        string `json:"body"`
	CreatedAt   string `json:"createdAt"`
	SubmittedAt string `json:"submittedAt"`
	State       string `json:"state"`
	Author      struct {
		Login    string `json:"login"`
		TypeName string `json:"__typename"`
	} `json:"author"`
}

type detailConnection struct {
	Nodes    []detailNode `json:"nodes"`
	PageInfo struct {
		HasPreviousPage bool   `json:"hasPreviousPage"`
		StartCursor     string `json:"startCursor"`
	} `json:"pageInfo"`
}

func normalizeBotLogin(login string, bot bool) string {
	if bot && login != "" {
		return strings.TrimSuffix(login, "[bot]") + "[bot]"
	}
	return login
}

func fetchDetails(ctx context.Context, pr state.PullRequest, old, current state.PullRequestStatus, hadPrior bool, stateAt string, log state.PullRequestEventLog, run, rest Runner, now time.Time, viewer string) ([]state.PullRequestEvent, map[string]string, HostResult) {
	var baseline time.Time
	for _, watcher := range pr.Watchers {
		if added, err := time.Parse(time.RFC3339Nano, watcher.AddedAt); err == nil && (baseline.IsZero() || added.Before(baseline)) {
			baseline = added
		}
	}
	lastIDs := map[string]string{}
	events := []state.PullRequestEvent{}
	hostResult := HostResult{}
	reopenedAt := ""
	for _, source := range []string{"comments", "reviews"} {
		var before string
		for {
			field := "id body createdAt author { login __typename }"
			if source == "reviews" {
				field = "id body submittedAt state author { login __typename }"
			}
			cursor := ""
			if before != "" {
				cursor = ",before:" + strconv.Quote(before)
			}
			reopenedQuery := ""
			if source == "comments" && before == "" && current.State == "open" && (old.State == "closed" || !hadPrior) {
				reopenedQuery = " timelineItems(last:1,itemTypes:[REOPENED_EVENT]) { nodes { ... on ReopenedEvent { createdAt } } }"
			}
			query := fmt.Sprintf("query { rateLimit { cost remaining resetAt } repository(owner:%s,name:%s) { pullRequest(number:%d) { %s(last:100%s) { nodes { %s } pageInfo { hasPreviousPage startCursor } }%s } } }", strconv.Quote(pr.Owner), strconv.Quote(pr.Repo), pr.Number, source, cursor, field, reopenedQuery)
			stdout, stderr, runErr := run(ctx, pr.Host, query)
			body, retry, reset := responseBody(stdout)
			var response graphResponse
			if err := json.Unmarshal(body, &response); err != nil || runErr != nil || len(response.Errors) > 0 {
				return nil, nil, detailFailure(now, retry, reset, response.Data.RateLimit, stderr, runErr)
			}
			hostResult.RateLimit = mergeRateLimit(hostResult.RateLimit, response.Data.RateLimit)
			if reset != "" {
				hostResult.BackoffUntil = reset
			}
			var repo struct {
				PullRequest map[string]json.RawMessage `json:"pullRequest"`
			}
			if err := json.Unmarshal(response.Data.Aliases["repository"], &repo); err != nil {
				return nil, nil, HostResult{Error: "invalid PR detail response"}
			}
			if reopenedQuery != "" {
				var timeline struct {
					Nodes []struct {
						CreatedAt string `json:"createdAt"`
					} `json:"nodes"`
				}
				if raw := repo.PullRequest["timelineItems"]; len(raw) > 0 {
					if err := json.Unmarshal(raw, &timeline); err != nil {
						return nil, nil, HostResult{Error: "invalid PR reopen timeline"}
					}
				}
				if len(timeline.Nodes) > 0 {
					reopenedAt = timeline.Nodes[len(timeline.Nodes)-1].CreatedAt
				}
			}
			var connection detailConnection
			if err := json.Unmarshal(repo.PullRequest[source], &connection); err != nil {
				return nil, nil, HostResult{Error: "invalid PR detail connection"}
			}
			if before == "" {
				for i := len(connection.Nodes) - 1; i >= 0; i-- {
					node := connection.Nodes[i]
					if source != "reviews" || node.SubmittedAt != "" && node.State != "PENDING" {
						lastIDs[source] = node.ID
						break
					}
				}
			}
			stop := false
			for i := len(connection.Nodes) - 1; i >= 0; i-- {
				node := connection.Nodes[i]
				if source == "reviews" && (node.State == "PENDING" || node.SubmittedAt == "") {
					continue
				}
				occurred := node.CreatedAt
				kind := "comment"
				if source == "reviews" {
					occurred, kind = node.SubmittedAt, "review"
				}
				if node.ID == log.LastIDs[source] {
					stop = true
					break
				}
				t, err := time.Parse(time.RFC3339Nano, occurred)
				if err != nil || t.Before(baseline) {
					stop = true
					break
				}
				bot := node.Author.TypeName == "Bot"
				if !bot && viewer != "" && strings.EqualFold(node.Author.Login, viewer) {
					continue
				}
				events = append(events, state.PullRequestEvent{ID: node.ID, Kind: kind, OccurredAt: occurred, Author: normalizeBotLogin(node.Author.Login, bot), Bot: bot, Body: node.Body, State: strings.ToLower(node.State)})
			}
			if response.Data.RateLimit != nil && response.Data.RateLimit.Remaining == 0 {
				return nil, nil, HostResult{Error: "GitHub rate limit exhausted", BackoffUntil: response.Data.RateLimit.ResetAt}
			}
			if stop || !connection.PageInfo.HasPreviousPage {
				break
			}
			if connection.PageInfo.StartCursor == "" || connection.PageInfo.StartCursor == before {
				return nil, nil, HostResult{Error: "PR detail pagination did not advance"}
			}
			before = connection.PageInfo.StartCursor
		}
	}
	for page := 1; ; page++ {
		endpoint := fmt.Sprintf("repos/%s/%s/pulls/%d/comments?sort=created&direction=desc&per_page=100&page=%d", url.PathEscape(pr.Owner), url.PathEscape(pr.Repo), pr.Number, page)
		stdout, stderr, runErr := rest(ctx, pr.Host, endpoint)
		body, retry, reset := responseBody(stdout)
		var nodes []struct {
			NodeID    string `json:"node_id"`
			Body      string `json:"body"`
			CreatedAt string `json:"created_at"`
			User      struct {
				Login string `json:"login"`
				Type  string `json:"type"`
			} `json:"user"`
		}
		if err := json.Unmarshal(body, &nodes); err != nil || runErr != nil {
			return nil, nil, detailFailure(now, retry, reset, nil, stderr, runErr)
		}
		if page == 1 && len(nodes) > 0 {
			lastIDs["review_comments"] = nodes[0].NodeID
		}
		stop := false
		for _, node := range nodes {
			if node.NodeID == log.LastIDs["review_comments"] {
				stop = true
				break
			}
			created, err := time.Parse(time.RFC3339Nano, node.CreatedAt)
			if err != nil || created.Before(baseline) {
				stop = true
				break
			}
			bot := node.User.Type == "Bot"
			if !bot && viewer != "" && strings.EqualFold(node.User.Login, viewer) {
				continue
			}
			events = append(events, state.PullRequestEvent{ID: node.NodeID, Kind: "review_comment", OccurredAt: node.CreatedAt, Author: normalizeBotLogin(node.User.Login, bot), Bot: bot, Body: node.Body})
		}
		if stop || len(nodes) < 100 {
			if reset != "" {
				hostResult.BackoffUntil = reset
			}
			break
		}
		if reset != "" {
			return nil, nil, HostResult{Error: "GitHub rate limit exhausted", BackoffUntil: reset}
		}
	}
	if current.State == "open" && reopenedAt != "" {
		stateAt = reopenedAt
	}
	if old.State != current.State && (current.State == "merged" || current.State == "closed" || current.State == "open") {
		if stateAt == "" && hadPrior {
			stateAt = current.UpdatedAt
		}
		if at, err := time.Parse(time.RFC3339Nano, stateAt); err == nil && !at.Before(baseline) {
			events = append(events, state.PullRequestEvent{ID: "state:" + current.State + ":" + stateAt, Kind: "state", State: current.State, OccurredAt: stateAt})
		}
	}
	if (old.CI != current.CI || old.HeadSHA != current.HeadSHA || ciRerunFinished(old, current)) && (current.CI == "success" || current.CI == "failure") {
		completed, err := time.Parse(time.RFC3339Nano, current.CICompletedAt)
		if err != nil {
			return nil, nil, HostResult{Error: "CI completion timestamp unavailable"}
		}
		// The finish time is part of the ID: a rerun on the same head with the same result is a new event.
		if !completed.Before(baseline) {
			events = append(events, state.PullRequestEvent{ID: "ci:" + current.HeadSHA + ":" + current.CI + ":" + current.CICompletedAt, Kind: "ci", Result: current.CI, HeadSHA: current.HeadSHA, OccurredAt: current.CICompletedAt})
		}
	}
	sort.Slice(events, func(i, j int) bool {
		if events[i].OccurredAt == events[j].OccurredAt {
			return events[i].ID < events[j].ID
		}
		return events[i].OccurredAt < events[j].OccurredAt
	})
	return events, lastIDs, hostResult
}

// ciRerunFinished reports a CI run that finished after the one the stored status saw, with the head and
// result unchanged. Both polls saw every check done, so no pending poll separates the two runs. A status
// stored before CICompletedAt existed has no earlier run to compare with, so it never matches.
func ciRerunFinished(old, current state.PullRequestStatus) bool {
	if old.CIRunning || current.CIRunning {
		return false
	}
	before, err := time.Parse(time.RFC3339Nano, old.CICompletedAt)
	if err != nil {
		return false
	}
	after, err := time.Parse(time.RFC3339Nano, current.CICompletedAt)
	return err == nil && after.After(before)
}

func detailFailure(now time.Time, retry, reset string, rate *RateLimit, stderr []byte, runErr error) HostResult {
	message := strings.TrimSpace(string(stderr))
	if message == "" && runErr != nil {
		message = runErr.Error()
	}
	if message == "" {
		message = "invalid GitHub detail response"
	}
	if reset != "" {
		rate = &RateLimit{Remaining: 0, ResetAt: reset}
	}
	return HostResult{Error: message, BackoffUntil: backoff(now, retry, rate, message)}
}

func mergeRateLimit(total, latest *RateLimit) *RateLimit {
	if latest == nil {
		return total
	}
	if total == nil {
		total = &RateLimit{}
	}
	total.Cost += latest.Cost
	total.Remaining = latest.Remaining
	total.ResetAt = latest.ResetAt
	return total
}
