package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/picker"
	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newPickerCmd(store *state.Store, client *tmux.Client, repoRoot string) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "picker",
		Short: "Interactive fzf-based session picker",
		Long: `Launch an interactive session picker using fzf.

Select a session with Enter to resume/attach, or press Ctrl-D to delete.
Requires fzf to be installed.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runPicker(cmd, store, client, repoRoot)
		},
	}

	cmd.AddCommand(newPickerPreviewCmd(store, client))
	cmd.AddCommand(newPickerEntriesCmd(store, client))

	return cmd
}

func runPicker(cmd *cobra.Command, store *state.Store, client *tmux.Client, repoRoot string) error {
	if !picker.FzfAvailable() {
		return fmt.Errorf("fzf is required for interactive picker. Install with: brew install fzf")
	}

	ctx := cmd.Context()
	entries, err := picker.BuildEntries(ctx, store, client)
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		fmt.Fprintln(cmd.OutOrStdout(), "No party sessions found.")
		return nil
	}

	formatted := picker.FormatEntries(entries)

	self, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve executable: %w", err)
	}
	previewCmd := fmt.Sprintf("%s picker preview $(echo {1} | tr -d ' ')", self)
	deleteCmd := fmt.Sprintf("echo {} | grep -qv 'current' && echo {} | awk '{print $1}' | xargs %s delete || true", self)
	reloadCmd := fmt.Sprintf("%s picker entries | column -t -s $'\\t'", self)

	header := "enter:resume  ctrl-d:delete  esc:cancel"
	target, err := picker.RunFzf(formatted, previewCmd, deleteCmd, reloadCmd, header)
	if err != nil {
		return err
	}
	if target == "" {
		return nil
	}

	// Route action based on session state.
	alive, _ := client.HasSession(ctx, target)
	svc := session.NewService(store, client, repoRoot)
	w := cmd.OutOrStdout()

	if alive {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
		return attachSession(target)
	}

	result, err := svc.Continue(ctx, target)
	if err != nil {
		return fmt.Errorf("continue %s: %w", target, err)
	}
	if result.Reattach {
		fmt.Fprintf(w, "Attaching to %s...\n", target)
	} else {
		fmt.Fprintf(w, "Resumed %s.\n", target)
	}
	return attachSession(target)
}

// attachSession switches to the named tmux session.
func attachSession(sessionID string) error {
	var cmd *exec.Cmd
	if os.Getenv("TMUX") != "" {
		cmd = exec.Command("tmux", "switch-client", "-t", sessionID)
	} else {
		cmd = exec.Command("tmux", "attach-session", "-t", sessionID)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	return cmd.Run()
}

// newPickerPreviewCmd is a hidden subcommand used by fzf's --preview.
func newPickerPreviewCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:    "preview <session-id>",
		Short:  "Render preview for a session (used by fzf)",
		Args:   cobra.ExactArgs(1),
		Hidden: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			sessionID := strings.TrimSpace(args[0])
			pd, err := picker.BuildPreview(cmd.Context(), sessionID, store, client)
			if err != nil {
				return err
			}
			fmt.Fprint(cmd.OutOrStdout(), picker.FormatPreview(pd))
			return nil
		},
	}
}

// newPickerEntriesCmd is a hidden subcommand used by fzf's reload binding.
func newPickerEntriesCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:    "entries",
		Short:  "Print picker entries (used by fzf reload)",
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
