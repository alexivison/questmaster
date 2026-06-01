package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
)

// editFileWithEditor opens path in $EDITOR (or $VISUAL), inheriting the
// terminal. Falls back to vi.
func editFileWithEditor(path string) error {
	editor := firstNonEmpty(os.Getenv("VISUAL"), os.Getenv("EDITOR"), "vi")
	// Allow editors configured with arguments (e.g. "code --wait").
	fields := strings.Fields(editor)
	args := append(fields[1:], path)
	cmd := exec.Command(fields[0], args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// openInBrowser opens path with the platform's default handler.
func openInBrowser(path string) error {
	var bin string
	var args []string
	switch runtime.GOOS {
	case "darwin":
		bin = "open"
	case "windows":
		bin, args = "rundll32", []string{"url.dll,FileProtocolHandler"}
	default:
		bin = "xdg-open"
	}
	args = append(args, path)
	cmd := exec.Command(bin, args...)
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("open %s: %w", path, err)
	}
	return nil
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
