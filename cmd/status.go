package cmd

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/spf13/cobra"
)

func newStatusCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "status <session-id>",
		Short: "Show detailed status of a party session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runStatus(cmd.Context(), cmd.OutOrStdout(), store, client, args[0])
		},
	}
}

func runStatus(ctx context.Context, w io.Writer, store *state.Store, client *tmux.Client, sessionID string) error {
	if !strings.HasPrefix(sessionID, "party-") {
		return fmt.Errorf("not a party session: %q", sessionID)
	}

	live, err := client.ListSessions(ctx)
	if err != nil {
		return fmt.Errorf("list tmux sessions: %w", err)
	}
	isLive := false
	for _, s := range live {
		if s == sessionID {
			isLive = true
			break
		}
	}

	m, readErr := store.Read(sessionID)
	if readErr != nil && !isLive {
		return fmt.Errorf("read manifest: %w", readErr)
	}

	status := "stale"
	if isLive {
		status = "active"
	}

	fmt.Fprintf(w, "Session:  %s\n", sessionID)
	fmt.Fprintf(w, "Status:   %s\n", status)

	if readErr != nil {
		if errors.Is(readErr, os.ErrNotExist) {
			fmt.Fprintf(w, "Manifest: missing\n")
		} else {
			fmt.Fprintf(w, "Manifest: corrupt (%v)\n", readErr)
		}
		return nil
	}

	stype := m.SessionType
	if stype == "" {
		stype = "regular"
	}
	fmt.Fprintf(w, "Type:     %s\n", stype)
	if m.Title != "" {
		fmt.Fprintf(w, "Title:    %s\n", m.Title)
	}
	if m.Cwd != "" {
		fmt.Fprintf(w, "Cwd:      %s\n", m.Cwd)
	}
	if m.CreatedAt != "" {
		fmt.Fprintf(w, "Created:  %s\n", m.CreatedAt)
	}
	if m.UpdatedAt != "" {
		fmt.Fprintf(w, "Updated:  %s\n", m.UpdatedAt)
	}
	if len(m.Workers) > 0 {
		fmt.Fprintf(w, "Workers:  %s\n", strings.Join(m.Workers, ", "))
	}

	return nil
}
