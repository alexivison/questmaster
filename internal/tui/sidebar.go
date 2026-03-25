package tui

import (
	"fmt"
	"strings"
	"time"
)

// RenderSidebar renders the Codex status section for the worker sidebar.
// Output uses a flat-list layout: section header on the first line, indented
// detail on the next. No hard-coded left gutters — the bordered pane handles
// padding.
func RenderSidebar(cs CodexStatus, width int) string {
	inner := width - 4 // match contentDimensions: 2 borders + 2 padding
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder

	switch cs.State {
	case CodexWorking:
		b.WriteString(sidebarLabelStyle.Render("Codex") + " " + spinnerStyle.Render("working") + "\n")
		var details []string
		if cs.Mode != "" {
			details = append(details, cs.Mode)
		}
		if cs.Target != "" {
			details = append(details, truncate(cs.Target, inner-10))
		}
		if cs.StartedAt != "" {
			if started, err := time.Parse(time.RFC3339, cs.StartedAt); err == nil {
				elapsed := time.Since(started).Truncate(time.Second)
				details = append(details, elapsed.String())
			}
		}
		if len(details) > 0 {
			b.WriteString("  " + sidebarValueStyle.Render(strings.Join(details, " · ")) + "\n")
		}

	case CodexIdle:
		b.WriteString(sidebarLabelStyle.Render("Codex") + " " + sidebarValueStyle.Render("idle") + "\n")
		var details []string
		if cs.Verdict != "" {
			details = append(details, verdictString(cs.Verdict))
		}
		if cs.FinishedAt != "" {
			if finished, err := time.Parse(time.RFC3339, cs.FinishedAt); err == nil {
				ago := time.Since(finished).Truncate(time.Second)
				details = append(details, sidebarValueStyle.Render(ago.String()+" ago"))
			}
		}
		if len(details) > 0 {
			b.WriteString("  " + strings.Join(details, " "+sidebarValueStyle.Render("·")+" ") + "\n")
		}

	case CodexError:
		b.WriteString(sidebarLabelStyle.Render("Codex") + " " + errorTextStyle.Render("error") + "\n")
		if cs.Error != "" {
			b.WriteString("  " + sidebarValueStyle.Render(truncate(cs.Error, inner-2)) + "\n")
		}

	case CodexOffline:
		b.WriteString(sidebarLabelStyle.Render("Codex") + " " + noteTextStyle.Render("offline") + "\n")
		b.WriteString("  " + noteTextStyle.Render("no status file") + "\n")

	default:
		b.WriteString(sidebarLabelStyle.Render("Codex") + " " + sidebarValueStyle.Render(string(cs.State)) + "\n")
	}

	return b.String()
}

// verdictString renders a verdict with the appropriate semantic style.
func verdictString(verdict string) string {
	switch verdict {
	case "APPROVE", "APPROVED":
		return activeTextStyle.Render(verdict)
	case "REQUEST_CHANGES", "NEEDS_DISCUSSION":
		return warnTextStyle.Render(verdict)
	default:
		return sidebarValueStyle.Render(verdict)
	}
}

// RenderWizardSnippet renders the last few lines of Wizard pane output.
func RenderWizardSnippet(snippet string, width int) string {
	inner := width - 4 // match contentDimensions: 2 borders + 2 padding
	if inner < 10 {
		inner = 10
	}

	indent := "  " // 2 spaces — aligns with detail lines (e.g. "4m19s ago")
	var b strings.Builder
	for _, line := range strings.Split(snippet, "\n") {
		b.WriteString(indent + dimTextStyle.Render(truncate(line, inner-2)) + "\n")
	}
	return b.String()
}

// RenderEvidence renders a compact evidence summary below the Codex status.
// Uses a flat-list layout: "Evidence" section header followed by indented
// sub-list entries.
func RenderEvidence(entries []EvidenceEntry, width int) string {
	if len(entries) == 0 {
		return ""
	}

	inner := width - 4 // match contentDimensions: 2 borders + 2 padding
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder
	b.WriteString(sidebarLabelStyle.Render("Evidence") + "\n")

	for _, e := range entries {
		// Truncate plain text before styling to avoid slicing ANSI sequences.
		maxType := inner - 2 - len(e.Result) - 1 // indent + result + space
		typeName := e.Type
		if maxType > 0 && len(typeName) > maxType {
			typeName = truncate(typeName, maxType)
		}
		b.WriteString(fmt.Sprintf("  %s %s", typeName, verdictString(e.Result)) + "\n")
	}

	return b.String()
}
