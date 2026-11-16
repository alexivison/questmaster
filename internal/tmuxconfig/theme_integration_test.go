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
	for _, tc := range []struct{ name, pane, window string }{
		{"legacy pane", "legacy", ""},
		{"legacy window", "", "legacy"},
		{"both legacy", "legacy", "legacy"},
		{"custom window beneath legacy pane", "legacy", "custom"},
		{"custom pane above legacy window", "custom", "legacy"},
		{"both custom", "custom", "custom"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, client, root := configServer(t)
			pane, err := client.NewSession(t.Context(), "qm-old", "sleep 60", root)
			if err != nil {
				t.Fatal(err)
			}
			legacy, err := os.ReadFile("assets/legacy-pane-border-format.txt")
			if err != nil {
				t.Fatal(err)
			}
			// Reproduce the managed override written by template v3's title code.
			mustTmux(t, r, "set-option", "-g", "pane-border-format", strings.TrimSpace(string(legacy)))
			if err := client.SetManagedPaneTitle(t.Context(), pane, "Original title"); err != nil {
				t.Fatal(err)
			}
			managed := mustTmux(t, r, "show-options", "-pqv", "-t", pane, "pane-border-format")
			mustTmux(t, r, "set-option", "-pu", "-t", pane, "pane-border-format")
			const custom = "custom #{pane_title}"
			otherWindow := mustTmux(t, r, "new-window", "-d", "-t", tmux.SessionTarget("qm-old"), "-n", "custom", "-P", "-F", "#{window_id}", "sleep 60")
			if err := client.SetWindowOption(t.Context(), otherWindow, "pane-border-format", custom); err != nil {
				t.Fatal(err)
			}
			formats := map[string]string{"legacy": managed, "custom": custom}
			if tc.window != "" {
				if err := client.SetWindowOption(t.Context(), pane, "pane-border-format", formats[tc.window]); err != nil {
					t.Fatal(err)
				}
			}
			if tc.pane != "" {
				if err := client.SetPaneOption(t.Context(), pane, "pane-border-format", formats[tc.pane]); err != nil {
					t.Fatal(err)
				}
			}
			if err := client.SetSessionOption(t.Context(), "qm-old", "@questmaster_session_accent", palette.Display("violet")); err != nil {
				t.Fatal(err)
			}
			result, err := tmuxconfig.Reload(t.Context(), client, root)
			if err != nil || len(result.Errors) != 0 {
				t.Fatalf("reload: %+v, %v", result, err)
			}
			if got := mustTmux(t, r, "show-options", "-wqv", "-t", otherWindow, "pane-border-format"); got != custom {
				t.Fatalf("another window's custom format changed: %q", got)
			}
			if tc.pane == "custom" || tc.window == "custom" {
				if got := mustTmux(t, r, "display-message", "-p", "-t", pane, "#{pane-border-format}"); got != custom {
					t.Fatalf("custom format changed: %q", got)
				}
			} else {
				got := mustTmux(t, r, "display-message", "-p", "-t", pane, "#{E:pane-border-format}")
				if !strings.Contains(got, "Original title") || !strings.Contains(got, palette.Display("violet")) {
					t.Fatalf("old pane retained its blue override: %q", got)
				}
			}
			// A new pane must inherit the migrated window, including when its
			// old format was hidden by a custom format on the original pane.
			added := mustTmux(t, r, "split-window", "-d", "-t", pane, "-P", "-F", "#{pane_id}", "sleep 60")
			got := mustTmux(t, r, "display-message", "-p", "-t", added, "#{pane-border-format}")
			if tc.window == "custom" {
				if got != custom {
					t.Fatalf("custom window format changed: %q", got)
				}
			} else if !strings.Contains(got, "#{@questmaster_session_accent}") {
				t.Fatalf("new pane retained a legacy window format: %q", got)
			}
		})
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
