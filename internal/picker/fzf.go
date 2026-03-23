package picker

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// Picker ANSI escape constants aligned to scry token vocabulary.
// Raw strings for fzf — no Lip Gloss dependency.
const (
	pickerResetANSI   = "\033[0m"
	pickerAccentANSI  = "\033[34m"       // ANSI 4 — Accent
	pickerCleanANSI   = "\033[32m"       // ANSI 2 — Clean / Added
	pickerMutedANSI   = "\033[90m"       // ANSI 8 — Muted
	pickerDividerANSI = "\033[38;5;240m" // ANSI 240 — DividerFg
)

// FormatEntries renders entries into fixed-width columns for fzf.
// Uses fixed widths instead of column(1) to avoid ANSI mangling on reload.
func FormatEntries(entries []Entry) string {
	var sb strings.Builder
	sep := pickerMutedANSI + " | " + pickerResetANSI
	for _, e := range entries {
		if e.IsSep {
			sb.WriteString(pickerDividerANSI + "── resumable ──────────────────────────────" + pickerResetANSI + "\n")
			continue
		}
		fmt.Fprintf(&sb, "%-26s%s%-18s%s%-20s%s%s\n", e.SessionID, sep, e.Status, sep, dash(e.Title), sep, dash(e.Cwd))
	}
	return sb.String()
}

// FormatPreview renders preview data into colored terminal output.
func FormatPreview(pd *PreviewData) string {
	if pd == nil {
		return "No manifest found."
	}

	var sb strings.Builder
	switch pd.Status {
	case "master":
		fmt.Fprintf(&sb, "%smaster%s %s(%d workers)%s\n", pickerAccentANSI, pickerResetANSI, pickerMutedANSI, pd.WorkerCount, pickerResetANSI)
	case "active":
		fmt.Fprintf(&sb, "%sactive%s\n", pickerCleanANSI, pickerResetANSI)
	default:
		fmt.Fprintf(&sb, "%sresumable%s\n", pickerMutedANSI, pickerResetANSI)
	}

	fmt.Fprintf(&sb, "%s%s%s\n", pickerMutedANSI, pd.Cwd, pickerResetANSI)
	fmt.Fprintf(&sb, "%s%s%s\n", pickerMutedANSI, pd.Timestamp, pickerResetANSI)

	if pd.Prompt != "" {
		fmt.Fprintf(&sb, "%sprompt: %s%s\n", pickerCleanANSI, pd.Prompt, pickerResetANSI)
	}
	if pd.ClaudeID != "" {
		fmt.Fprintf(&sb, "%sclaude: %s%s\n", pickerMutedANSI, pd.ClaudeID, pickerResetANSI)
	}
	if pd.CodexID != "" {
		fmt.Fprintf(&sb, "%swizard: %s%s\n", pickerMutedANSI, pd.CodexID, pickerResetANSI)
	}

	if len(pd.PaneLines) > 0 {
		fmt.Fprintf(&sb, "\n%s--- Paladin ---%s\n", pickerAccentANSI, pickerResetANSI)
		for _, line := range pd.PaneLines {
			if strings.HasPrefix(line, "❯") {
				fmt.Fprintf(&sb, "%s%s%s\n", pickerCleanANSI, line, pickerResetANSI)
			} else {
				fmt.Fprintf(&sb, "%s%s%s\n", pickerAccentANSI, line, pickerResetANSI)
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
