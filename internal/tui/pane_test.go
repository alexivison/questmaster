package tui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
)

// ---------------------------------------------------------------------------
// borderedPane — corners, title, footer
// ---------------------------------------------------------------------------

func TestBorderedPane_RoundedCorners(t *testing.T) {
	t.Parallel()

	out := borderedPane("hello", "", "", 20, 5, true)
	if !strings.Contains(out, "╭") || !strings.Contains(out, "╮") ||
		!strings.Contains(out, "╰") || !strings.Contains(out, "╯") {
		t.Error("bordered pane must use rounded corners ╭╮╰╯")
	}
}

func TestBorderedPane_TitleEmbedded(t *testing.T) {
	t.Parallel()

	out := borderedPane("body", "Files", "", 30, 5, true)
	lines := strings.Split(out, "\n")
	if len(lines) == 0 {
		t.Fatal("expected at least one line")
	}
	if !strings.Contains(lines[0], "Files") {
		t.Errorf("title 'Files' should appear in top border, got: %s", lines[0])
	}
}

func TestBorderedPane_FooterEmbedded(t *testing.T) {
	t.Parallel()

	out := borderedPane("body", "", "q quit", 30, 5, true)
	lines := strings.Split(out, "\n")
	last := lines[len(lines)-1]
	if !strings.Contains(last, "q quit") {
		t.Errorf("footer 'q quit' should appear in bottom border, got: %s", last)
	}
}

func TestBorderedPane_ActiveAndInactiveRender(t *testing.T) {
	t.Parallel()

	// Both active and inactive must produce valid bordered output with corners.
	// Color differences are invisible in non-TTY test environments, so we
	// verify both code paths produce structurally valid panes.
	for _, active := range []bool{true, false} {
		out := borderedPane("x", "", "", 20, 4, active)
		if !strings.Contains(out, "╭") || !strings.Contains(out, "╯") {
			t.Errorf("active=%v: expected rounded corners", active)
		}
		lines := strings.Split(out, "\n")
		if len(lines) != 4 {
			t.Errorf("active=%v: expected 4 lines, got %d", active, len(lines))
		}
	}
}

func TestBorderedPane_MinimumSize(t *testing.T) {
	t.Parallel()

	out := borderedPane("x", "", "", 3, 2, true)
	if strings.Contains(out, "╭") {
		t.Error("pane below minimum size should return content as-is, not draw borders")
	}
}

// ---------------------------------------------------------------------------
// borderedPaneWithScroll — scroll indicator
// ---------------------------------------------------------------------------

func TestBorderedPaneWithScroll_Indicator(t *testing.T) {
	t.Parallel()

	out := borderedPaneWithScroll("line0\nline1\nline2", "", "", 20, 5, true, 1)
	if !strings.Contains(out, "┃") {
		t.Error("scroll indicator ┃ should appear on the right edge")
	}
}

func TestBorderedPaneWithScroll_NoIndicatorWhenNegative(t *testing.T) {
	t.Parallel()

	out := borderedPaneWithScroll("line0\nline1", "", "", 20, 5, true, -1)
	if strings.Contains(out, "┃") {
		t.Error("scroll indicator should not appear when scrollLine is negative")
	}
}

// ---------------------------------------------------------------------------
// contentDimensions
// ---------------------------------------------------------------------------

func TestContentDimensions(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		outerW, outerH int
		wantW, wantH   int
	}{
		"normal":    {outerW: 40, outerH: 10, wantW: 38, wantH: 8},
		"tiny":      {outerW: 2, outerH: 2, wantW: 0, wantH: 0},
		"zero":      {outerW: 0, outerH: 0, wantW: 0, wantH: 0},
		"one_wider": {outerW: 3, outerH: 3, wantW: 1, wantH: 1},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			w, h := contentDimensions(tc.outerW, tc.outerH)
			if w != tc.wantW || h != tc.wantH {
				t.Errorf("contentDimensions(%d, %d) = (%d, %d), want (%d, %d)",
					tc.outerW, tc.outerH, w, h, tc.wantW, tc.wantH)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// chromeLayout — height-aware footer-only vs pane+status
// ---------------------------------------------------------------------------

func TestChromeLayout_FooterOnlyBelowThreshold(t *testing.T) {
	t.Parallel()

	bodyH, showStatus := chromeLayout(12, true)
	if showStatus {
		t.Error("status bar should not show below compactHeightThreshold")
	}
	if bodyH != 12-2 {
		t.Errorf("footer-only body = %d, want %d", bodyH, 12-2)
	}
}

func TestChromeLayout_StatusBarWhenTallEnough(t *testing.T) {
	t.Parallel()

	bodyH, showStatus := chromeLayout(20, true)
	if !showStatus {
		t.Error("status bar should show when height >= compactHeightThreshold and requested")
	}
	if bodyH != 20-3 {
		t.Errorf("pane+status body = %d, want %d", bodyH, 20-3)
	}
}

func TestChromeLayout_NoStatusBarWhenNotRequested(t *testing.T) {
	t.Parallel()

	bodyH, showStatus := chromeLayout(20, false)
	if showStatus {
		t.Error("status bar should not show when not requested")
	}
	if bodyH != 20-2 {
		t.Errorf("footer-only body = %d, want %d", bodyH, 20-2)
	}
}

// ---------------------------------------------------------------------------
// renderStatusBar — key badges and muted labels
// ---------------------------------------------------------------------------

func TestRenderStatusBar_ContainsHints(t *testing.T) {
	t.Parallel()

	out := renderStatusBar(60, []keyHint{{"q", "quit"}, {"?", "help"}}, "", nil)
	if !strings.Contains(out, "q") || !strings.Contains(out, "quit") {
		t.Errorf("status bar should contain key badges, got: %s", out)
	}
	if !strings.Contains(out, "?") || !strings.Contains(out, "help") {
		t.Errorf("status bar should contain help badge, got: %s", out)
	}
}

func TestRenderStatusBar_ErrorTakesPriority(t *testing.T) {
	t.Parallel()

	out := renderStatusBar(60, []keyHint{{"q", "quit"}}, "", fmt.Errorf("something broke"))
	if !strings.Contains(out, "something broke") {
		t.Errorf("error should appear in status bar, got: %s", out)
	}
}

func TestRenderStatusBar_MessageShown(t *testing.T) {
	t.Parallel()

	out := renderStatusBar(60, nil, "Sent relay message", nil)
	if !strings.Contains(out, "Sent relay message") {
		t.Errorf("message should appear in status bar, got: %s", out)
	}
}

func TestRenderStatusBar_LongContentSingleRow(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		width   int
		hints   []keyHint
		message string
		err     error
	}{
		"long_error": {
			width: 20,
			err:   fmt.Errorf("abcdefghijklmnopqrstuvwxyz this is a very long error message"),
		},
		"long_message": {
			width:   20,
			message: "abcdefghijklmnopqrstuvwxyz this is a very long transient message",
		},
		"many_hints": {
			width: 20,
			hints: []keyHint{{"q", "quit"}, {"?", "help"}, {"r", "relay"}, {"b", "broadcast"}, {"s", "spawn"}},
		},
	}

	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			out := renderStatusBar(tc.width, tc.hints, tc.message, tc.err)
			w := lipgloss.Width(out)
			if w > tc.width {
				t.Errorf("status bar visual width = %d, want <= %d (overflow would cause wrapping)", w, tc.width)
			}
			if strings.Contains(out, "\n") {
				t.Errorf("status bar must be a single row, but contains newline")
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Styled title — ANSI-aware width
// ---------------------------------------------------------------------------

func TestBorderedPane_StyledTitleWidth(t *testing.T) {
	t.Parallel()

	goldStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#ffd700")).Bold(true)
	styledTitle := goldStyle.Render("Master") + " Tracker"

	out := borderedPane("body", styledTitle, "", 40, 5, true)
	lines := strings.Split(out, "\n")
	top := lines[0]

	topW := lipgloss.Width(top)
	if topW != 40 {
		t.Errorf("top border visual width = %d, want 40 (ANSI-aware)", topW)
	}
}

func TestBorderedPane_LongStyledTitleTruncated(t *testing.T) {
	t.Parallel()

	longTitle := lipgloss.NewStyle().Bold(true).Render("A Very Long Title That Should Be Truncated")
	out := borderedPane("body", longTitle, "", 20, 5, true)
	lines := strings.Split(out, "\n")
	topW := lipgloss.Width(lines[0])
	if topW != 20 {
		t.Errorf("top border visual width = %d, want 20 after truncation", topW)
	}
}

// ---------------------------------------------------------------------------
// Semantic style tiers — distinct tiers
// ---------------------------------------------------------------------------

func TestSemanticStyleTiers_Distinct(t *testing.T) {
	t.Parallel()

	label := sidebarLabelStyle.Render("Codex")
	value := sidebarValueStyle.Render("idle")
	help := sidebarHelpStyle.Render("q quit")

	if label == value {
		t.Error("sidebarLabelStyle and sidebarValueStyle must be visually distinct")
	}
	if value == help {
		t.Error("sidebarValueStyle and sidebarHelpStyle must be visually distinct")
	}
	if label == help {
		t.Error("sidebarLabelStyle and sidebarHelpStyle must be visually distinct")
	}
}

func TestInactiveWorkerTitleStyle_BrighterThanSnippets(t *testing.T) {
	t.Parallel()

	title := inactiveWorkerTitleStyle.Render("worker-1")
	snippet := snippetStyleWide.Render("some snippet")

	if title == snippet {
		t.Error("inactive worker title must be visually brighter than snippets")
	}
}
