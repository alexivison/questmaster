package tmuxconfig

import (
	"context"
	_ "embed"
	"errors"
	"strings"

	"github.com/alexivison/questmaster/internal/tmux"
)

// Frozen template-v3 format, used only to recognize the old stock pane override.
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
	panes, err := client.RunBatch(ctx, []string{"list-panes", "-a", "-F", "#{pane_id}\t#{pane-border-format}"})
	if err != nil {
		return err
	}
	const title = "#{?#{==:#{@questmaster_title},},#{pane_title},#{@questmaster_title}}"
	legacy := strings.ReplaceAll(strings.TrimSpace(legacyBorderFormat), "#{pane_title}", title)
	for _, line := range strings.Split(panes, "\n") {
		pane, format, ok := strings.Cut(line, "\t")
		if !ok || format != legacy {
			continue
		}
		if _, err := client.RunBatch(ctx, []string{"set-option", "-pu", "-t", pane, "pane-border-format"}); err != nil {
			// Older tmux versions stored the managed override on the window.
			if _, fallbackErr := client.RunBatch(ctx, []string{"set-option", "-wu", "-t", pane, "pane-border-format"}); fallbackErr != nil {
				return errors.Join(err, fallbackErr)
			}
		}
	}
	return nil
}
