package picker

import (
	"fmt"
	"io"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"

	"github.com/anthropics/ai-party/tools/party-cli/internal/palette"
)

// Column widths for entry layout.
const (
	colTitle = 24
	colID    = 20
	colAgent = 8
	colType  = 14
)

var (
	formatRenderer = lipgloss.NewRenderer(io.Discard)

	formatTitleStyle      lipgloss.Style
	formatMutedStyle      lipgloss.Style
	formatFaintMutedStyle lipgloss.Style
	formatAccentStyle     lipgloss.Style
	formatCleanStyle      lipgloss.Style
	formatWarnStyle       lipgloss.Style
	formatDividerStyle    lipgloss.Style
	formatMasterStyle     lipgloss.Style
)

func init() {
	formatRenderer.SetColorProfile(termenv.ANSI)
	formatTitleStyle = formatRenderer.NewStyle().Bold(true)
	formatMutedStyle = formatRenderer.NewStyle().Foreground(palette.Muted)
	formatFaintMutedStyle = formatRenderer.NewStyle().Foreground(palette.Muted).Faint(true)
	formatAccentStyle = formatRenderer.NewStyle().Foreground(palette.Accent)
	formatCleanStyle = formatRenderer.NewStyle().Foreground(palette.Clean)
	formatWarnStyle = formatRenderer.NewStyle().Foreground(palette.Warn)
	formatDividerStyle = formatRenderer.NewStyle().Foreground(palette.DividerFg)
	formatMasterStyle = formatRenderer.NewStyle().Foreground(palette.MasterRole)
}

// FormatEntries renders entries into fixed-width columns for fzf.
// Each field is truncated to its column width to prevent overflow.
func FormatEntries(entries []Entry) string {
	var sb strings.Builder
	for _, e := range entries {
		if e.IsSep {
			sb.WriteString(formatDividerStyle.Render("  ── resumable ─────────────────────────────────────────────"))
			sb.WriteByte('\n')
			continue
		}
		renderEntry(&sb, &e)
	}
	return sb.String()
}

// renderEntry formats a single picker row: dot Title PartyID Type Path.
func renderEntry(sb *strings.Builder, e *Entry) {
	dot, typeStyle := entryStyle(e)

	id := strings.TrimSpace(e.SessionID)
	sb.WriteString(dot)
	sb.WriteString(formatTitleStyle.Render(padRight(truncStr(dash(e.Title), colTitle), colTitle)))
	sb.WriteString("  ")
	sb.WriteString(formatMutedStyle.Render(padRight(truncStr(id, colID), colID)))
	sb.WriteString("  ")
	renderAgentColumn(sb, e.PrimaryAgent)
	sb.WriteString("  ")
	sb.WriteString(typeStyle.Render(padRight(truncStr(entryTypeLabel(e), colType), colType)))
	sb.WriteString("  ")
	sb.WriteString(formatMutedStyle.Render(dash(e.Cwd)))
	sb.WriteByte('\n')
}

// entryStyle returns the status dot and type color for an entry.
func entryStyle(e *Entry) (string, lipgloss.Style) {
	switch {
	case strings.Contains(e.Status, "master"):
		return formatMasterStyle.Render("● "), formatMasterStyle
	case strings.Contains(e.Status, "worker"):
		return formatWarnStyle.Render("│ "), formatWarnStyle
	case strings.Contains(e.Status, "orphan"):
		return formatMutedStyle.Render("○ "), formatMutedStyle
	case strings.Contains(e.Status, "tmux"):
		return formatAccentStyle.Render("● "), formatAccentStyle
	case strings.Contains(e.Status, "active"), strings.Contains(e.Status, "current"):
		return formatCleanStyle.Render("● "), formatCleanStyle
	default:
		return formatMutedStyle.Render("○ "), formatFaintMutedStyle
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
		return formatMutedStyle.Render("  No manifest found.")
	}

	var sb strings.Builder
	sb.WriteByte('\n')
	switch pd.Status {
	case "master":
		sb.WriteString("  ")
		sb.WriteString(formatMasterStyle.Bold(true).Render("● master"))
		sb.WriteString("  ")
		sb.WriteString(formatMutedStyle.Render(fmt.Sprintf("%d workers", pd.WorkerCount)))
		sb.WriteByte('\n')
	case "active":
		sb.WriteString("  ")
		sb.WriteString(formatCleanStyle.Bold(true).Render("● active"))
		sb.WriteByte('\n')
	case "tmux":
		sb.WriteString("  ")
		sb.WriteString(formatAccentStyle.Bold(true).Render("● tmux"))
		sb.WriteByte('\n')
	default:
		sb.WriteString("  ")
		sb.WriteString(formatMutedStyle.Render("○ resumable"))
		sb.WriteByte('\n')
	}

	sb.WriteByte('\n')
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

	if pd.Prompt != "" {
		sb.WriteByte('\n')
		sb.WriteString("  ")
		sb.WriteString(formatAccentStyle.Bold(true).Render("prompt"))
		sb.WriteByte('\n')
		for _, line := range wrapText(pd.Prompt, 40) {
			sb.WriteString("  ")
			sb.WriteString(formatCleanStyle.Render(line))
			sb.WriteByte('\n')
		}
	}

	if len(pd.PaneLines) > 0 {
		sb.WriteByte('\n')
		label := "paladin"
		if pd.Status == "tmux" {
			label = "terminal"
		}
		sb.WriteString("  ")
		sb.WriteString(formatAccentStyle.Bold(true).Render(label))
		sb.WriteByte('\n')
		for _, line := range pd.PaneLines {
			style := formatFaintMutedStyle
			if strings.HasPrefix(line, "❯") || strings.HasPrefix(line, "$") {
				style = formatCleanStyle
			}
			sb.WriteString("  ")
			sb.WriteString(style.Render(line))
			sb.WriteByte('\n')
		}
	}

	return sb.String()
}

// previewField renders a label: value pair for the preview pane.
func previewField(sb *strings.Builder, label, value string) {
	sb.WriteString("  ")
	sb.WriteString(formatDividerStyle.Render(fmt.Sprintf("%-7s", label)))
	sb.WriteByte(' ')
	sb.WriteString(formatMutedStyle.Render(value))
	sb.WriteByte('\n')
}

func renderAgentColumn(sb *strings.Builder, agent string) {
	value := padRight(truncStr(dash(agent), colAgent), colAgent)
	if agent == "" {
		sb.WriteString(formatMutedStyle.Render(value))
		return
	}
	sb.WriteString(formatTitleStyle.Render(value))
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
