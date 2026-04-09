package cmd

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-party/tools/party-cli/internal/picker"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newPickerCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "picker",
		Short: "Interactive session picker",
		Long: `Launch an interactive session picker.

Select a session with Enter to resume/attach, or press Ctrl-D to delete.
Navigate with j/k or arrow keys.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPicker(cmd, store, client, repoRoot)
		},
	}

	cmd.AddCommand(newPickerEntriesCmd(store, client))

	return cmd
}

// newPickerEntriesCmd prints formatted entries to stdout (used by party.sh --pick-entries).
func newPickerEntriesCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:    "entries",
		Short:  "Print picker entries",
		Hidden: true,
		RunE: func(cmd *cobra.Command, _ []string) error {
			entries, err := picker.BuildEntries(cmd.Context(), store, client)
			if err != nil {
				return err
			}
			fmt.Fprint(cmd.OutOrStdout(), picker.FormatEntries(entries))
			return nil
		},
	}
}

func runPicker(cmd *cobra.Command, store *state.Store, client *tmux.Client, repoRoot string) error {
	ctx := cmd.Context()
	entries, err := picker.BuildEntries(ctx, store, client)
	if err != nil {
		return err
	}
	currentSession, _ := client.CurrentSessionName(ctx)
	tmuxEntries, err := picker.BuildTmuxEntries(ctx, client, currentSession)
	if err != nil {
		return err
	}
	if len(entries) == 0 && len(tmuxEntries) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No sessions found.")
		return nil
	}

	svc := session.NewService(store, client, repoRoot)
	deleteFn := func(ctx context.Context, sessionID string) error {
		if strings.HasPrefix(sessionID, "party-") {
			return svc.Delete(ctx, sessionID)
		}
		return client.KillSession(ctx, sessionID)
	}
	m := picker.NewModel(ctx, entries, tmuxEntries, store, client, deleteFn)

	p := tea.NewProgram(m, tea.WithAltScreen())
	result, err := p.Run()
	if err != nil {
		return fmt.Errorf("picker: %w", err)
	}

	target := result.(picker.Model).Selected()
	if target == "" {
		return nil
	}

	alive, _ := client.HasSession(ctx, target)
	w := cmd.OutOrStdout()

	if alive {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
		return attachSession(ctx, client, target)
	}

	// Only party sessions can be resumed from a stale state.
	if !strings.HasPrefix(target, "party-") {
		return nil
	}

	res, err := svc.Continue(ctx, target)
	if err != nil {
		return fmt.Errorf("continue %s: %w", target, err)
	}
	if res.Reattach {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
	} else {
		fmt.Fprintf(w, "Resumed %s.\n", target)
	}
	return attachSession(ctx, client, target)
}

// attachSession switches to the named tmux session.
func attachSession(ctx context.Context, client *tmux.Client, sessionID string) error {
	if os.Getenv("TMUX") != "" {
		return client.SwitchClientWithFallback(ctx, sessionID)
	}
	cmd := exec.Command("tmux", "attach-session", "-t", sessionID)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
