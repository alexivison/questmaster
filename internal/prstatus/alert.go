package prstatus

import (
	"fmt"
	"strings"
	"unicode"

	"github.com/alexivison/questmaster/internal/state"
)

const alertMaxBytes = 200

func alertText(pr state.PullRequest, events []state.PullRequestEvent) string {
	ref := fmt.Sprintf("%s/%s#%d", pr.Owner, pr.Repo, pr.Number)
	if pr.Host != "github.com" {
		ref = fmt.Sprintf("https://%s/%s/%s/pull/%d", pr.Host, pr.Owner, pr.Repo, pr.Number)
	}
	prefix := "[PR " + ref + "] "
	suffix := "; run: questmaster pr events " + ref + " --unread (duplicates possible)"
	comments := 0
	reviews := 0
	var latestReview, latestCI, latestState string
	for _, event := range events {
		switch event.Kind {
		case "comment", "review_comment":
			comments++
		case "review":
			reviews++
			stateName := sanitizeAlertField(strings.ReplaceAll(event.State, "_", " "), 24)
			if stateName == "" {
				stateName = "submitted"
			}
			part := "review: " + stateName
			if author := sanitizeAlertField(event.Author, 24); author != "" {
				part += " by " + author
			}
			latestReview = part
		case "ci":
			latestCI = "CI: " + sanitizeAlertField(event.Result, 16)
		case "state":
			latestState = "PR: " + sanitizeAlertField(event.State, 16)
		}
	}
	parts := []string{}
	if comments > 0 {
		noun := "comments"
		if comments == 1 {
			noun = "comment"
		}
		parts = append(parts, fmt.Sprintf("%d %s", comments, noun))
	}
	if reviews > 1 {
		latestReview = fmt.Sprintf("%d reviews; latest %s", reviews, latestReview)
	}
	for _, part := range []string{latestReview, latestCI, latestState} {
		if part != "" {
			parts = append(parts, part)
		}
	}
	if len(parts) == 0 {
		parts = []string{"activity"}
	}
	for len(parts) > 0 {
		text := prefix + strings.Join(parts, ", ") + suffix
		if len(text) <= alertMaxBytes {
			return text
		}
		parts = parts[:len(parts)-1]
	}
	if text := prefix + "activity" + suffix; len(text) <= alertMaxBytes {
		return text
	}
	if text := prefix + "activity; run: questmaster pr events <ref> --unread (duplicates possible)"; len(text) <= alertMaxBytes {
		return text
	}
	if text := prefix + "activity (duplicates possible)"; len(text) <= alertMaxBytes {
		return text
	}
	// ponytail: a ref over the wire limit cannot fit in full; point to the watch list if one appears.
	return "[PR activity] ref too long; run questmaster pr ls (duplicates possible)"
}

func sanitizeAlertField(raw string, limit int) string {
	var b strings.Builder
	for _, r := range raw {
		if r == '\n' || r == '\r' {
			break
		}
		if unicode.IsControl(r) {
			continue
		}
		if r == ';' || r == '[' || r == ']' || r == '`' {
			r = ' '
		}
		if b.Len()+len(string(r)) > limit {
			break
		}
		b.WriteRune(r)
	}
	return strings.Join(strings.Fields(b.String()), " ")
}
