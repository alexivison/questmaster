package tui

import (
	"fmt"
	"strings"
)

// RenderSidebar renders the Codex status section for the worker sidebar.
// Output uses a flat-list layout: section header on the first line, indented
// detail on the next. No hard-coded left gutters — the bordered pane handles
// padding.
func RenderSidebar(cs CodexStatus, width int) string {
	inner := width - borderlessMargin
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder

	switch cs.State {
	case CodexWorking:
		b.WriteString(sidebarLabelStyle.Render(LabelWizard) + " " + spinnerStyle.Render("working") + "\n")
		var details []string
		if cs.Mode != "" {
			details = append(details, cs.Mode)
		}
		if cs.Target != "" {
			details = append(details, truncate(cs.Target, inner-10))
		}
		if len(details) > 0 {
			b.WriteString("  " + sidebarValueStyle.Render(strings.Join(details, " · ")) + "\n")
		}

	case CodexIdle:
		b.WriteString(sidebarLabelStyle.Render(LabelWizard) + " " + sidebarValueStyle.Render("idle") + "\n")
		var details []string
		if cs.Verdict != "" {
			details = append(details, verdictString(cs.Verdict))
		}
		if len(details) > 0 {
			b.WriteString("  " + strings.Join(details, " "+sidebarValueStyle.Render("·")+" ") + "\n")
		}

	case CodexError:
		b.WriteString(sidebarLabelStyle.Render(LabelWizard) + " " + errorTextStyle.Render("error") + "\n")
		if cs.Error != "" {
			b.WriteString("  " + sidebarValueStyle.Render(truncate(cs.Error, inner-2)) + "\n")
		}

	case CodexOffline:
		b.WriteString(sidebarLabelStyle.Render(LabelWizard) + " " + noteTextStyle.Render("offline") + "\n")
		b.WriteString("  " + noteTextStyle.Render("no status file") + "\n")

	default:
		b.WriteString(sidebarLabelStyle.Render(LabelWizard) + " " + sidebarValueStyle.Render(string(cs.State)) + "\n")
	}

	return b.String()
}

// verdictString renders a verdict with the appropriate semantic style.
func verdictString(verdict string) string {
	switch verdict {
	case "APPROVE", "APPROVED", "PASS":
		return activeTextStyle.Render(verdict)
	case "REQUEST_CHANGES", "FAIL":
		return errorTextStyle.Render(verdict)
	case "NEEDS_DISCUSSION":
		return warnTextStyle.Render(verdict)
	default:
		return sidebarValueStyle.Render(verdict)
	}
}

// RenderWizardSnippet renders the last few lines of Wizard pane output.
func RenderWizardSnippet(snippet string, width int) string {
	inner := width - borderlessMargin
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

	inner := width - borderlessMargin
	if inner < 10 {
		inner = 10
	}

	// Deduplicate: keep only the latest entry per base type.
	deduped := latestPerBaseType(entries)

	var b strings.Builder
	b.WriteString(sidebarLabelStyle.Render(LabelEvidence) + "\n")

	for _, e := range deduped {
		maxType := inner - 2 - len(e.Result) - 1 // indent + result + space
		typeName := e.Type
		if maxType > 0 && len(typeName) > maxType {
			typeName = truncate(typeName, maxType)
		}
		b.WriteString(fmt.Sprintf("  %s %s", typeName, verdictString(e.Result)) + "\n")
	}

	return b.String()
}

// latestPerBaseType deduplicates evidence entries by base type (stripping
// suffixes like -fp, -run) and returns the latest entry per base type,
// preserving the original order of first appearance.
func latestPerBaseType(entries []EvidenceEntry) []EvidenceEntry {
	seen := make(map[string]*EvidenceEntry)
	var order []string

	for _, e := range entries {
		base := evidenceBaseType(e.Type)
		e.Type = base
		if existing, ok := seen[base]; ok {
			// Replace unless existing holds a real verdict and new is a hash.
			if isHexHash(existing.Result) || !isHexHash(e.Result) {
				*existing = e
			}
		} else {
			order = append(order, base)
			eCopy := e
			seen[base] = &eCopy
		}
	}

	result := make([]EvidenceEntry, len(order))
	for i, base := range order {
		result[i] = *seen[base]
	}
	return result
}

// evidenceBaseType strips known suffixes (-fp, -run) from evidence type names.
func evidenceBaseType(t string) string {
	for _, suffix := range []string{"-fp", "-run"} {
		if strings.HasSuffix(t, suffix) {
			return strings.TrimSuffix(t, suffix)
		}
	}
	return t
}

// isHexHash returns true if s looks like a hex-encoded hash (40+ hex chars).
func isHexHash(s string) bool {
	if len(s) < 40 {
		return false
	}
	for _, c := range s {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
