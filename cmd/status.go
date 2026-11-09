package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
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

func newStatusCmd(store *state.Store, client *tmux.Client, routes ...*tmuxroute.Router) *cobra.Command {
	return &cobra.Command{
		Use:   "status <session-id>",
		Short: "Show detailed status of a questmaster session",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			router, err := commandRouter(store, client, routes)
			if err != nil {
				return err
			}
			result, err := collectStatusRouted(cmd.Context(), store, client, router, args[0])
			if err != nil {
				return err
			}
			return writeJSON(cmd.OutOrStdout(), result)
		},
	}
}

func collectStatus(ctx context.Context, store *state.Store, client *tmux.Client, sessionID string) (statusJSONOutput, error) {
	router, err := tmuxroute.NewProduction(store, client)
	if err != nil {
		return statusJSONOutput{}, err
	}
	return collectStatusRouted(ctx, store, client, router, sessionID)
}

func collectStatusRouted(ctx context.Context, store *state.Store, client *tmux.Client, router *tmuxroute.Router, sessionID string) (statusJSONOutput, error) {
	if !state.IsValidSessionID(sessionID) {
		return statusJSONOutput{}, fmt.Errorf("not a questmaster session ID: %q", sessionID)
	}

	m, readErr := store.Read(sessionID)
	if readErr == nil {
		handle, err := router.Route(m)
		if err != nil {
			return statusJSONOutput{}, err
		}
		client = handle.Client()
	} else {
		inventory, err := router.CompleteInventory(ctx)
		if err != nil {
			return statusJSONOutput{}, err
		}
		var server string
		for _, row := range inventory.Rows {
			if row.ID != sessionID {
				continue
			}
			if server != "" {
				return statusJSONOutput{}, fmt.Errorf("session %s exists on multiple tmux servers", sessionID)
			}
			server = row.Label
		}
		if server == "" {
			return statusJSONOutput{}, fmt.Errorf("read manifest: %w", readErr)
		}
		handle, err := router.Route(state.Manifest{TmuxServer: state.TmuxServer(server)})
		if err != nil {
			return statusJSONOutput{}, err
		}
		client = handle.Client()
	}
	isLive, liveErr := client.HasSession(ctx, sessionID)
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

	result.Manifest = statusManifestJSON{
		Present:     true,
		SessionType: m.SessionRole(),
		Title:       m.Title,
		Cwd:         m.Cwd,
		CreatedAt:   m.CreatedAt,
		UpdatedAt:   m.UpdatedAt,
		Workers:     m.Workers,
	}
	return result, nil
}
