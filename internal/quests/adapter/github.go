package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/quests/runtime"
)

// prQuery fetches the most recent PR for a head branch with its CI rollup and
// review decision. It mirrors projdash's read-only GraphQL shape.
const prQuery = `query($owner:String!,$name:String!,$branch:String!){
  repository(owner:$owner,name:$name){
    pullRequests(headRefName:$branch, first:1, states:[OPEN,MERGED], orderBy:{field:UPDATED_AT, direction:DESC}){
      nodes{
        number url
        reviewDecision
        commits(last:1){ nodes{ commit{ statusCheckRollup{ state } } } }
      }
    }
  }
}`

// GitHubStatusSource reads PR/CI status from GitHub. Query is the transport and
// is injectable so unit tests run offline; the default shells out to
// `gh api graphql` (the projdash read path).
type GitHubStatusSource struct {
	// Query returns the raw GraphQL JSON for a repo branch.
	Query func(repo, branch string) ([]byte, error)
}

var _ StatusSource = (*GitHubStatusSource)(nil)

// NewGitHubStatusSource returns a source backed by the `gh` CLI.
func NewGitHubStatusSource() *GitHubStatusSource {
	return &GitHubStatusSource{Query: ghGraphQL}
}

// PR returns the PR/CI status for repo ("owner/name") on branch, or nil if no
// PR exists for that branch.
func (g *GitHubStatusSource) PR(repo, branch string) (*runtime.PRStatus, error) {
	raw, err := g.Query(repo, branch)
	if err != nil {
		return nil, err
	}
	return parsePRStatus(raw)
}

// graphQLResponse is the subset of the GitHub GraphQL response we read.
type graphQLResponse struct {
	Data struct {
		Repository struct {
			PullRequests struct {
				Nodes []struct {
					Number         int    `json:"number"`
					URL            string `json:"url"`
					ReviewDecision string `json:"reviewDecision"`
					Commits        struct {
						Nodes []struct {
							Commit struct {
								StatusCheckRollup *struct {
									State string `json:"state"`
								} `json:"statusCheckRollup"`
							} `json:"commit"`
						} `json:"nodes"`
					} `json:"commits"`
				} `json:"nodes"`
			} `json:"pullRequests"`
		} `json:"repository"`
	} `json:"data"`
}

// parsePRStatus maps a GraphQL response to a PRStatus. Returns (nil, nil) when
// the branch has no PR.
func parsePRStatus(raw []byte) (*runtime.PRStatus, error) {
	var resp graphQLResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("parse github response: %w", err)
	}
	nodes := resp.Data.Repository.PullRequests.Nodes
	if len(nodes) == 0 {
		return nil, nil
	}
	n := nodes[0]

	ci := "none"
	if len(n.Commits.Nodes) > 0 {
		if rollup := n.Commits.Nodes[0].Commit.StatusCheckRollup; rollup != nil {
			ci = mapCIState(rollup.State)
		}
	}
	return &runtime.PRStatus{
		Number: n.Number,
		URL:    n.URL,
		CI:     ci,
		Review: mapReviewDecision(n.ReviewDecision),
	}, nil
}

// mapCIState maps a GitHub statusCheckRollup state to the PRStatus vocabulary.
func mapCIState(state string) string {
	switch strings.ToUpper(state) {
	case "SUCCESS":
		return "green"
	case "PENDING", "EXPECTED":
		return "pending"
	case "FAILURE", "ERROR":
		return "failed"
	default:
		return "none"
	}
}

// mapReviewDecision maps a GitHub reviewDecision to the PRStatus vocabulary.
func mapReviewDecision(decision string) string {
	switch strings.ToUpper(decision) {
	case "APPROVED":
		return "approved"
	case "CHANGES_REQUESTED":
		return "changes"
	case "REVIEW_REQUIRED":
		return "pending"
	default:
		return "pending"
	}
}

// ghGraphQL is the default transport: shell out to the gh CLI. Not exercised by
// unit tests (which inject Query).
func ghGraphQL(repo, branch string) ([]byte, error) {
	owner, name, err := splitRepo(repo)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "gh", "api", "graphql",
		"-f", "query="+prQuery,
		"-F", "owner="+owner,
		"-F", "name="+name,
		"-F", "branch="+branch,
	)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("gh api graphql: %w", err)
	}
	return out, nil
}

func splitRepo(repo string) (owner, name string, err error) {
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return "", "", fmt.Errorf("invalid repo %q (want owner/name)", repo)
	}
	return parts[0], parts[1], nil
}
