package picker

import (
	"fmt"
	"strings"
)

// Picker ANSI escape constants aligned to scry token vocabulary.
// Raw strings for fzf — no Lip Gloss dependency.
const (
	pickerResetANSI   = "\033[0m"
	pickerBoldANSI    = "\033[1m"
	pickerFaintANSI   = "\033[2m"
	pickerAccentANSI  = "\033[34m"             // ANSI 4 — Accent
	pickerCleanANSI   = "\033[32m"             // ANSI 2 — Clean
	pickerWarnANSI    = "\033[33m"             // ANSI 3 — Dirty/Warn
	pickerMutedANSI   = "\033[90m"             // ANSI 8 — Muted
	pickerDividerANSI = "\033[38;5;240m"       // ANSI 240 — DividerFg
	pickerGoldANSI    = "\033[38;2;255;215;0m" // #ffd700 — Master identity
)

// Column widths for entry layout.
const (
	colTitle = 24
	colID    = 20
	colAgent = 8
	colType  = 14
)

// FormatEntries renders entries into fixed-width columns for fzf.
// Each field is truncated to its column width to prevent overflow.
func FormatEntries(entries []Entry) string {
	var sb strings.Builder
	for _, e := range entries {
		if e.IsSep {
			sb.WriteString(pickerDividerANSI + "  ── resumable ─────────────────────────────────────────────" + pickerResetANSI + "\n")
			continue
		}
		renderEntry(&sb, &e)
	}
	return sb.String()
}

// renderEntry formats a single picker row: dot Title PartyID Type Path.
func renderEntry(sb *strings.Builder, e *Entry) {
	dot, typeColor := entryStyle(e)

	id := strings.TrimSpace(e.SessionID)

	sb.WriteString(dot)

	// Title
	title := dash(e.Title)
	sb.WriteString(pickerBoldANSI)
	sb.WriteString(padRight(truncStr(title, colTitle), colTitle))
	sb.WriteString(pickerResetANSI)
	sb.WriteString("  ")

	// PartyID — always muted
	sb.WriteString(pickerMutedANSI)
	sb.WriteString(padRight(truncStr(id, colID), colID))
	sb.WriteString(pickerResetANSI)
	sb.WriteString("  ")

	// Primary agent
	renderAgentColumn(sb, e.PrimaryAgent)
	sb.WriteString("  ")

	// Type
	sb.WriteString(typeColor)
	sb.WriteString(padRight(truncStr(entryTypeLabel(e), colType), colType))
	sb.WriteString(pickerResetANSI)
	sb.WriteString("  ")

	// Path
	sb.WriteString(pickerMutedANSI)
	sb.WriteString(dash(e.Cwd))
	sb.WriteString(pickerResetANSI)
	sb.WriteString("\n")
}

// entryStyle returns the status dot and type color for an entry.
func entryStyle(e *Entry) (dot, typeColor string) {
	switch {
	case strings.Contains(e.Status, "master"):
		return pickerGoldANSI + "● " + pickerResetANSI, pickerGoldANSI
	case strings.Contains(e.Status, "worker"):
		return pickerWarnANSI + "│ " + pickerResetANSI, pickerWarnANSI
	case strings.Contains(e.Status, "orphan"):
		return pickerMutedANSI + "○ " + pickerResetANSI, pickerMutedANSI
	case strings.Contains(e.Status, "tmux"):
		return pickerAccentANSI + "● " + pickerResetANSI, pickerAccentANSI
	case strings.Contains(e.Status, "active"), strings.Contains(e.Status, "current"):
		return pickerCleanANSI + "● " + pickerResetANSI, pickerCleanANSI
	default:
		return pickerMutedANSI + "○ " + pickerResetANSI, pickerMutedANSI + pickerFaintANSI
	}
}

// entryTypeLabel returns a short type label for the entry.
func entryTypeLabel(e *Entry) string {
	switch {
	case strings.Contains(e.Status, "master"):
		return "master"
	case strings.Contains(e.Status, "orphan"):
		return "worker (orphan)"
	case strings.Contains(e.Status, "worker"):
		return "worker"
	case strings.Contains(e.Status, "tmux"):
		return "tmux"
	default:
		return "session"
	}
}

// FormatPreview renders preview data into a styled terminal output matching sidebar aesthetics.
func FormatPreview(pd *PreviewData) string {
	if pd == nil {
		return pickerMutedANSI + "  No manifest found." + pickerResetANSI
	}

	var sb strings.Builder

	// Status badge.
	sb.WriteString("\n")
	switch pd.Status {
	case "master":
		fmt.Fprintf(&sb, "  %s● master%s  %s%d workers%s\n", pickerGoldANSI+pickerBoldANSI, pickerResetANSI, pickerMutedANSI, pd.WorkerCount, pickerResetANSI)
	case "active":
		fmt.Fprintf(&sb, "  %s● active%s\n", pickerCleanANSI+pickerBoldANSI, pickerResetANSI)
	case "tmux":
		fmt.Fprintf(&sb, "  %s● tmux%s\n", pickerAccentANSI+pickerBoldANSI, pickerResetANSI)
	default:
		fmt.Fprintf(&sb, "  %s○ resumable%s\n", pickerMutedANSI, pickerResetANSI)
	}

	// Metadata section.
	sb.WriteString("\n")
	previewField(&sb, "dir", pd.Cwd)
	if pd.Timestamp != "" {
		previewField(&sb, "time", pd.Timestamp)
	}
	if pd.PrimaryAgent != "" {
		previewField(&sb, "primary", pd.PrimaryAgent)
	}
	if pd.ClaudeID != "" {
		previewField(&sb, "claude", pd.ClaudeID)
	}
	if pd.CodexID != "" {
		previewField(&sb, "wizard", pd.CodexID)
	}

	// Prompt section.
	if pd.Prompt != "" {
		sb.WriteString("\n")
		fmt.Fprintf(&sb, "  %sprompt%s\n", pickerAccentANSI+pickerBoldANSI, pickerResetANSI)
		// Wrap prompt at ~40 chars for readability in preview pane.
		for _, line := range wrapText(pd.Prompt, 40) {
			fmt.Fprintf(&sb, "  %s%s%s\n", pickerCleanANSI, line, pickerResetANSI)
		}
	}

	// Pane output.
	if len(pd.PaneLines) > 0 {
		sb.WriteString("\n")
		label := "paladin"
		if pd.Status == "tmux" {
			label = "terminal"
		}
		fmt.Fprintf(&sb, "  %s%s%s\n", pickerAccentANSI+pickerBoldANSI, label, pickerResetANSI)
		for _, line := range pd.PaneLines {
			color := pickerMutedANSI + pickerFaintANSI
			if strings.HasPrefix(line, "❯") || strings.HasPrefix(line, "$") {
				color = pickerCleanANSI
			}
			fmt.Fprintf(&sb, "  %s%s%s\n", color, line, pickerResetANSI)
		}
	}

	return sb.String()
}

// previewField renders a label: value pair for the preview pane.
func previewField(sb *strings.Builder, label, value string) {
	fmt.Fprintf(sb, "  %s%-7s%s %s%s%s\n", pickerDividerANSI, label, pickerResetANSI, pickerMutedANSI, value, pickerResetANSI)
}

func renderAgentColumn(sb *strings.Builder, agent string) {
	value := dash(agent)
	if agent == "" {
		sb.WriteString(pickerMutedANSI)
	} else {
		sb.WriteString(pickerBoldANSI)
	}
	sb.WriteString(padRight(truncStr(value, colAgent), colAgent))
	sb.WriteString(pickerResetANSI)
}

// wrapText splits text into lines of at most width characters, breaking at spaces.
func wrapText(s string, width int) []string {
	if len(s) <= width {
		return []string{s}
	}
	words := strings.Fields(s)
	var lines []string
	var current strings.Builder
	for _, w := range words {
		if current.Len() > 0 && current.Len()+1+len(w) > width {
			lines = append(lines, current.String())
			current.Reset()
		}
		if current.Len() > 0 {
			current.WriteByte(' ')
		}
		current.WriteString(w)
	}
	if current.Len() > 0 {
		lines = append(lines, current.String())
	}
	return lines
}

// truncStr truncates a string to max runes, appending "…" if needed.
func truncStr(s string, max int) string {
	if len(s) <= max {
		return s
	}
	if max <= 1 {
		return "…"
	}
	return s[:max-1] + "…"
}

// padRight pads a string with spaces to the given width.
func padRight(s string, width int) string {
	if len(s) >= width {
		return s
	}
	return s + strings.Repeat(" ", width-len(s))
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
