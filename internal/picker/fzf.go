package picker

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// FormatEntries renders entries into fixed-width columns for fzf.
// Uses fixed widths instead of column(1) to avoid ANSI mangling on reload.
func FormatEntries(entries []Entry) string {
	var sb strings.Builder
	for _, e := range entries {
		if e.IsSep {
			sb.WriteString("\033[38;2;99;110;123m── resumable ──────────────────────────────\033[0m\n")
			continue
		}
		dim := "\033[38;2;68;76;86m"
		reset := "\033[0m"
		sep := dim + " | " + reset
		fmt.Fprintf(&sb, "%-26s%s%-18s%s%-20s%s%s\n", e.SessionID, sep, e.Status, sep, dash(e.Title), sep, dash(e.Cwd))
	}
	return sb.String()
}

// FormatPreview renders preview data into colored terminal output.
func FormatPreview(pd *PreviewData) string {
	if pd == nil {
		return "No manifest found."
	}
	blue := "\033[38;2;83;155;245m"
	green := "\033[38;2;87;171;90m"
	dim := "\033[38;2;99;110;123m"
	reset := "\033[0m"

	var sb strings.Builder
	switch pd.Status {
	case "master":
		fmt.Fprintf(&sb, "%smaster%s %s(%d workers)%s\n", blue, reset, dim, pd.WorkerCount, reset)
	case "active":
		fmt.Fprintf(&sb, "%sactive%s\n", green, reset)
	default:
		fmt.Fprintf(&sb, "%sresumable%s\n", dim, reset)
	}

	fmt.Fprintf(&sb, "%s%s%s\n", dim, pd.Cwd, reset)
	fmt.Fprintf(&sb, "%s%s%s\n", dim, pd.Timestamp, reset)

	if pd.Prompt != "" {
		fmt.Fprintf(&sb, "%sprompt: %s%s\n", green, pd.Prompt, reset)
	}
	if pd.ClaudeID != "" {
		fmt.Fprintf(&sb, "%sclaude: %s%s\n", dim, pd.ClaudeID, reset)
	}
	if pd.CodexID != "" {
		fmt.Fprintf(&sb, "%scodex: %s%s\n", dim, pd.CodexID, reset)
	}

	if len(pd.PaneLines) > 0 {
		fmt.Fprintf(&sb, "\n%s--- Paladin ---%s\n", blue, reset)
		for _, line := range pd.PaneLines {
			if strings.HasPrefix(line, "❯") {
				fmt.Fprintf(&sb, "%s%s%s\n", green, line, reset)
			} else {
				fmt.Fprintf(&sb, "%s%s%s\n", blue, line, reset)
			}
		}
	}

	return sb.String()
}

// FzfAvailable reports whether fzf is on PATH.
func FzfAvailable() bool {
	_, err := exec.LookPath("fzf")
	return err == nil
}

// RunFzf launches fzf with the given entries and preview command.
// Returns the selected session ID or empty string on cancel.
func RunFzf(entries string, previewCmd string, deleteCmd string, reloadCmd string, header string) (string, error) {
	args := []string{
		"--ansi",
		"--header=" + header,
		"--no-info",
		"--reverse",
		"--preview=" + previewCmd,
		"--preview-window=right:40%",
	}

	args = append(args, "--bind=ctrl-d:execute("+deleteCmd+")+reload("+reloadCmd+")")

	cmd := exec.Command("fzf", args...)
	cmd.Stdin = strings.NewReader(entries)
	cmd.Stderr = os.Stderr

	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			code := exitErr.ExitCode()
			if code == 130 || code == 1 {
				return "", nil // cancelled or no match
			}
		}
		return "", fmt.Errorf("fzf: %w", err)
	}

	selected := strings.TrimSpace(string(out))
	fields := strings.Fields(selected)
	if len(fields) == 0 {
		return "", nil
	}

	target := fields[0]
	if !strings.HasPrefix(target, "party-") {
		return "", nil
	}
	return target, nil
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
