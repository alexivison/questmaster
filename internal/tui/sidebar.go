package tui

import (
	"fmt"
	"strings"
)

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

func verdictSymbol(verdict string) string {
	switch verdict {
	case "APPROVE", "APPROVED", "PASS":
		return activeTextStyle.Render("✓")
	case "REQUEST_CHANGES", "FAIL":
		return errorTextStyle.Render("!")
	case "NEEDS_DISCUSSION":
		return warnTextStyle.Render("?")
	default:
		return sidebarValueStyle.Render("•")
	}
}

func renderRoleLine(sessionType string, _ int, width int) string {
	label := sidebarLabelStyle.Render("role:")
	role := sessionType
	if role == "" {
		role = "unknown"
	}
	return fitBar(label+" "+role, width)
}

func renderCompanionLine(agentName string, status CompanionStatus, width int) string {
	label := sidebarLabelStyle.Render(strings.ToLower(LabelCompanion) + ":")
	if agentName == "" {
		return fitBar(label+" "+noteTextStyle.Render("none"), width)
	}

	parts := []string{string(status.State)}
	if status.Verdict != "" {
		parts = append(parts, status.Verdict)
	}
	if status.Mode != "" {
		parts = append(parts, "mode="+status.Mode)
	}
	if status.Target != "" {
		parts = append(parts, "target="+status.Target)
	}
	if status.Error != "" {
		parts = append(parts, status.Error)
	}
	return fitBar(fmt.Sprintf("%s %s (%s)", label, agentName, strings.Join(parts, ", ")), width)
}

func renderEvidenceLine(entries []EvidenceEntry, width int) string {
	label := sidebarLabelStyle.Render(strings.ToLower(LabelEvidence) + ":")
	if len(entries) == 0 {
		return fitBar(label+" "+noteTextStyle.Render("none"), width)
	}

	deduped := latestPerBaseType(entries)
	parts := make([]string, 0, len(deduped))
	for _, e := range deduped {
		parts = append(parts, fmt.Sprintf("%s %s", e.Type, verdictSymbol(e.Result)))
	}
	return fitBar(label+" "+strings.Join(parts, "  "), width)
}

func renderSnippetBlock(snippet string, width int) string {
	if snippet == "" {
		return ""
	}

	inner := width - 2
	if inner < 10 {
		inner = 10
	}

	var b strings.Builder
	for _, line := range strings.Split(snippet, "\n") {
		b.WriteString("  " + dimTextStyle.Render(truncate(line, inner)) + "\n")
	}
	return strings.TrimRight(b.String(), "\n")
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
