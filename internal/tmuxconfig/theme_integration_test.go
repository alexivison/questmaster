package tmuxconfig_test

import (
	"os"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestIntegrationThemeAdoptionPreservesCustomPaneFormats(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	oldPane, err := client.NewSession(t.Context(), "qm-old", "sleep 60", root)
	if err != nil {
		t.Fatal(err)
	}
	customPane, err := client.NewSession(t.Context(), "qm-custom", "sleep 60", root)
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := os.ReadFile("assets/legacy-pane-border-format.txt")
	if err != nil {
		t.Fatal(err)
	}
	// Reproduce how template v3 and SetManagedPaneTitle created a pane override.
	mustTmux(t, r, "set-option", "-g", "pane-border-format", strings.TrimSpace(string(legacy)))
	if err := client.SetManagedPaneTitle(t.Context(), oldPane, "Original title"); err != nil {
		t.Fatal(err)
	}
	const custom = "custom #{pane_title}"
	if err := client.SetPaneOption(t.Context(), customPane, "pane-border-format", custom); err != nil {
		t.Fatal(err)
	}
	if err := client.SetSessionOption(t.Context(), "qm-old", "@questmaster_session_accent", palette.Display("violet")); err != nil {
		t.Fatal(err)
	}
	result, err := tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || len(result.Errors) != 0 {
		t.Fatalf("reload: %+v, %v", result, err)
	}
	got := mustTmux(t, r, "display-message", "-p", "-t", oldPane, "#{E:pane-border-format}")
	if !strings.Contains(got, "Original title") || !strings.Contains(got, palette.Display("violet")) {
		t.Fatalf("old pane retained its blue override: %q", got)
	}
	if got := mustTmux(t, r, "display-message", "-p", "-t", customPane, "#{pane-border-format}"); got != custom {
		t.Fatalf("custom format changed: %q", got)
	}
}

func TestIntegrationThemeFollowsEachSession(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	r, client, root := configServer(t)
	for _, name := range []string{"qm-alpha", "qm-beta"} {
		mustTmux(t, r, "new-session", "-d", "-s", name, "sleep 60")
	}
	for _, step := range []struct{ session, color string }{
		{"qm-alpha", "violet"}, {"qm-beta", "green"}, {"qm-alpha", "pink"}, {"qm-alpha", "none"},
	} {
		if err := client.SetSessionOption(t.Context(), step.session, "@questmaster_session_accent", palette.Display(step.color)); err != nil {
			t.Fatal(err)
		}
		for _, option := range []string{"pane-active-border-style", "window-status-current-format", "message-style", "mode-style"} {
			got := mustTmux(t, r, "display-message", "-p", "-t", tmux.SessionTarget(step.session), "#{E:"+option+"}")
			if !strings.Contains(got, palette.Display(step.color)) {
				t.Errorf("%s %s = %q, want %s", step.session, option, got, palette.Display(step.color))
			}
		}
	}
	if err := client.SetManagedPaneTitle(t.Context(), tmux.SessionTarget("qm-beta"), "Sample title"); err != nil {
		t.Fatal(err)
	}
	for _, color := range []string{"sky", "orange"} {
		if err := client.SetSessionOption(t.Context(), "qm-beta", "@questmaster_session_accent", palette.Display(color)); err != nil {
			t.Fatal(err)
		}
		got := mustTmux(t, r, "display-message", "-p", "-t", tmux.SessionTarget("qm-beta"), "#{E:pane-border-format}")
		if !strings.Contains(got, "Sample title") || !strings.Contains(got, palette.Display(color)) {
			t.Fatalf("managed pane title did not retain its dynamic accent: %q", got)
		}
	}
	result, err := tmuxconfig.Reload(t.Context(), client, root)
	if err != nil || len(result.Errors) != 0 {
		t.Fatalf("reload: %+v, %v", result, err)
	}
	if got := mustTmux(t, r, "display-message", "-p", "-t", tmux.SessionTarget("qm-beta"), "#{@questmaster_session_accent}"); got != palette.Display("orange") {
		t.Fatalf("reload lost the session accent: %q", got)
	}
	// A user-created window inherits the same session accent without a hook.
	mustTmux(t, r, "new-window", "-d", "-t", tmux.SessionTarget("qm-beta"), "-n", "extra", "sleep 60")
	got := mustTmux(t, r, "display-message", "-p", "-t", "=qm-beta:extra", "#{E:pane-active-border-style}")
	if !strings.Contains(got, palette.Display("orange")) {
		t.Fatalf("new window lost session accent: %q", got)
	}
}
