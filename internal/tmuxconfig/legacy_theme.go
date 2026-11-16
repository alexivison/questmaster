package tmuxconfig

import (
	"context"
	_ "embed"
	"strconv"
	"strings"

	"github.com/alexivison/questmaster/internal/tmux"
)

// Frozen template-v3 format, used only to recognize the old stock border override.
// Current colours always come from the shared palette.
//
//go:embed assets/legacy-pane-border-format.txt
var legacyBorderFormat string

// upgradeManagedBorders removes only the stock format that older versions
// copied onto titled panes. It would otherwise hide the new global theme.
// Custom pane formats remain untouched, and the title stays in its user option.
func upgradeManagedBorders(ctx context.Context, client *tmux.Client) error {
	global, err := client.RunBatch(ctx, []string{"show-options", "-gqv", "pane-border-format"})
	if err != nil || !strings.Contains(global, "#{@questmaster_session_accent}") || !strings.Contains(global, "#{@questmaster_title}") {
		return err
	}
	panes, err := client.RunBatch(ctx, []string{"list-panes", "-a", "-F", "#{pane_id}\t#{window_id}\t#{pane-border-format}"})
	if err != nil {
		return err
	}
	const title = "#{?#{==:#{@questmaster_title},},#{pane_title},#{@questmaster_title}}"
	legacy := strings.ReplaceAll(strings.TrimSpace(legacyBorderFormat), "#{pane_title}", title)
	var windows, legacyPanes []string
	seenWindows := map[string]bool{}
	for _, line := range strings.Split(panes, "\n") {
		fields := strings.SplitN(line, "\t", 3)
		if len(fields) != 3 {
			continue
		}
		if !seenWindows[fields[1]] {
			seenWindows[fields[1]] = true
			windows = append(windows, fields[1])
		}
		if fields[2] == legacy {
			legacyPanes = append(legacyPanes, fields[0])
		}
	}
	// Format expansion includes the active pane's override even in
	// list-windows. Read window options at their own scope, including windows
	// hidden beneath custom pane formats. Batch the reads in one tmux command
	// queue per group rather than spawning a client for every window.
	const windowBatchSize = 32
	for start := 0; start < len(windows); start += windowBatchSize {
		end := min(start+windowBatchSize, len(windows))
		var command []string
		for _, window := range windows[start:end] {
			if len(command) != 0 {
				command = append(command, ";")
			}
			command = append(command, "display-message", "-p", "-t", window, window, ";", "show-options", "-wq", "-t", window, "pane-border-format")
		}
		options, err := client.RunBatch(ctx, command)
		if err != nil {
			return err
		}
		window := ""
		for _, line := range strings.Split(options, "\n") {
			if seenWindows[line] {
				window = line
			} else if window != "" && line == "pane-border-format "+strconv.Quote(legacy) {
				if _, err := client.RunBatch(ctx, []string{"set-option", "-wu", "-t", window, "pane-border-format"}); err != nil {
					return err
				}
			}
		}
	}
	for _, pane := range legacyPanes {
		// -q tolerates older tmux versions where only the window could own
		// this option. An unset of an inherited value is otherwise a no-op.
		if _, err := client.RunBatch(ctx, []string{"set-option", "-pqu", "-t", pane, "pane-border-format"}); err != nil {
			return err
		}
	}
	return nil
}
