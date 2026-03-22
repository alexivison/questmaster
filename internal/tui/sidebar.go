package tui

import (
	"fmt"
	"strings"
	"time"
)

// RenderSidebar renders the Codex status section for the worker sidebar.
// width is the total available terminal width (0 treated as minimum).
func RenderSidebar(cs CodexStatus, width int) string {
	inner := width - 4
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder

	switch cs.State {
	case CodexWorking:
		b.WriteString(activeStyle.Render("  Codex: working") + "\n")
		if cs.Mode != "" {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  mode: %s", cs.Mode)) + "\n")
		}
		if cs.Target != "" {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  target: %s", truncate(cs.Target, inner-10))) + "\n")
		}
		if cs.StartedAt != "" {
			if started, err := time.Parse(time.RFC3339, cs.StartedAt); err == nil {
				elapsed := time.Since(started).Truncate(time.Second)
				b.WriteString(dimStyle.Render(fmt.Sprintf("  elapsed: %s", elapsed)) + "\n")
			}
		}

	case CodexIdle:
		b.WriteString(dimStyle.Render("  Codex: idle") + "\n")
		if cs.Verdict != "" {
			style := dimStyle
			if cs.Verdict == "APPROVE" {
				style = activeStyle
			} else if cs.Verdict == "REQUEST_CHANGES" || cs.Verdict == "NEEDS_DISCUSSION" {
				style = warnStyle
			}
			b.WriteString(style.Render(fmt.Sprintf("  verdict: %s", cs.Verdict)) + "\n")
		}
		if cs.FinishedAt != "" {
			if finished, err := time.Parse(time.RFC3339, cs.FinishedAt); err == nil {
				ago := time.Since(finished).Truncate(time.Second)
				b.WriteString(dimStyle.Render(fmt.Sprintf("  finished: %s ago", ago)) + "\n")
			}
		}

	case CodexError:
		b.WriteString(errorStyle.Render("  Codex: error") + "\n")
		if cs.Error != "" {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  %s", truncate(cs.Error, inner-4))) + "\n")
		}

	case CodexOffline:
		b.WriteString(dimStyle.Render("  Codex: offline") + "\n")
		b.WriteString(dimStyle.Render("  no status file") + "\n")

	default:
		b.WriteString(dimStyle.Render(fmt.Sprintf("  Codex: %s", cs.State)) + "\n")
	}

	return b.String()
}

// RenderEvidence renders a compact evidence summary below the Codex status.
func RenderEvidence(entries []EvidenceEntry, width int) string {
	if len(entries) == 0 {
		return ""
	}

	inner := width - 4
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder
	b.WriteString(dimStyle.Render("  Evidence:") + "\n")

	for _, e := range entries {
		style := dimStyle
		switch e.Result {
		case "APPROVED":
			style = activeStyle
		case "REQUEST_CHANGES":
			style = warnStyle
		}
		line := fmt.Sprintf("  %s: %s", e.Type, e.Result)
		b.WriteString(style.Render(truncate(line, inner)) + "\n")
	}

	return b.String()
}
