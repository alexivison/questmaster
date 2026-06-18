package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/spf13/cobra"
)

type statusJSONOutput struct {
	SessionID string             `json:"session_id"`
	Status    string             `json:"status"`
	Manifest  statusManifestJSON `json:"manifest"`
}

type statusManifestJSON struct {
	Present     bool     `json:"present"`
	Corrupt     bool     `json:"corrupt,omitempty"`
	Error       string   `json:"error,omitempty"`
	SessionType string   `json:"session_type,omitempty"`
	Title       string   `json:"title,omitempty"`
	Cwd         string   `json:"cwd,omitempty"`
	CreatedAt   string   `json:"created_at,omitempty"`
	UpdatedAt   string   `json:"updated_at,omitempty"`
	Workers     []string `json:"workers,omitempty"`
}

func newStatusCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "status <session-id>",
		Short: "Show detailed status of a questmaster session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			result, err := collectStatus(cmd.Context(), store, client, args[0])
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), result)
		},
	}
}

func collectStatus(ctx context.Context, store *state.Store, client *tmux.Client, sessionID string) (statusJSONOutput, error) {
	if !state.IsValidSessionID(sessionID) {
		return statusJSONOutput{}, fmt.Errorf("not a questmaster session ID: %q", sessionID)
	}

	isLive, liveErr := client.HasSession(ctx, sessionID)

	m, readErr := store.Read(sessionID)
	if readErr != nil && !isLive && liveErr == nil {
		return statusJSONOutput{}, fmt.Errorf("read manifest: %w", readErr)
	}

	result := statusJSONOutput{SessionID: sessionID, Status: "error"}
	if liveErr == nil {
		results := sessionactivity.Evaluate([]sessionactivity.Observation{{
			Key:       sessionID,
			SessionID: sessionID,
			Enabled:   isLive,
		}})
		result.Status = sessionactivity.Label(results[sessionID].State, isLive)
	}

	if readErr != nil {
		if errors.Is(readErr, os.ErrNotExist) {
			result.Manifest = statusManifestJSON{Present: false, Error: "missing"}
		} else {
			result.Manifest = statusManifestJSON{Present: false, Corrupt: true, Error: readErr.Error()}
		}
		return result, nil
	}

	stype := m.SessionType
	if stype == "" {
		stype = "regular"
	}
	result.Manifest = statusManifestJSON{
		Present:     true,
		SessionType: stype,
		Title:       m.Title,
		Cwd:         m.Cwd,
		CreatedAt:   m.CreatedAt,
		UpdatedAt:   m.UpdatedAt,
		Workers:     m.Workers,
	}
	return result, nil
}
