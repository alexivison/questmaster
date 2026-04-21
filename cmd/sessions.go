package cmd

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/sessionactivity"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tui"
	"github.com/spf13/cobra"
)

const activityStateFilename = "activity.json"

type sessionsJSONRow struct {
	PartyID       string `json:"party_id"`
	Title         string `json:"title"`
	SessionType   string `json:"session_type"`
	ParentSession string `json:"parent_session,omitempty"`
	PrimaryTool   string `json:"primary_tool,omitempty"`
	Active        bool   `json:"active"`
	LastChangeMS  int64  `json:"last_change_ms,omitempty"`
	Cwd           string `json:"cwd,omitempty"`
}

func newSessionsCmd(store *state.Store, client *tmux.Client) *cobra.Command {
	return &cobra.Command{
		Use:   "sessions",
		Short: "Emit live party sessions as JSON for integrations",
		Long: `List live party sessions in tracker order.

This command is intended for integrations such as SketchyBar. Activity is
derived from the same primary-pane snippet-change logic the tracker uses.
A session is reported active=true when its primary pane's visible content
changed within the last 3 seconds; active=false otherwise. The session is
always emitted regardless of the active flag, so consumers can render
idle sessions too.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runSessions(cmd.OutOrStdout(), store, client)
		},
	}
}

func runSessions(w io.Writer, store *state.Store, client *tmux.Client) error {
	snapshot, err := tui.NewLiveSessionFetcher(client, store)(tui.SessionInfo{})
	if err != nil {
		return err
	}

	observedAt, activeRows, observations := collectActiveSessions(snapshot)
	results, err := evaluateSessionActivity(store, observedAt, observations)
	if err != nil {
		return err
	}

	rows := make([]sessionsJSONRow, 0, len(activeRows))
	for _, row := range activeRows {
		result := results[sessionactivity.PrimaryKey(row.ID)]
		out := sessionsJSONRow{
			PartyID:       row.ID,
			Title:         row.Title,
			SessionType:   row.SessionType,
			ParentSession: row.ParentID,
			PrimaryTool:   row.PrimaryAgent,
			Active:        result.Active,
			Cwd:           row.Cwd,
		}
		if result.Active && !result.LastChangeAt.IsZero() {
			out.LastChangeMS = result.LastChangeAt.UnixMilli()
		}
		rows = append(rows, out)
	}

	enc := json.NewEncoder(w)
	return enc.Encode(rows)
}

func collectActiveSessions(snapshot tui.TrackerSnapshot) (time.Time, []tui.SessionRow, []sessionactivity.Observation) {
	observedAt := snapshot.ObservedAt
	if observedAt.IsZero() {
		observedAt = time.Now()
	}

	activeRows := make([]tui.SessionRow, 0, len(snapshot.Sessions))
	observations := make([]sessionactivity.Observation, 0, len(snapshot.Sessions))
	for _, row := range snapshot.Sessions {
		if row.Status != "active" {
			continue
		}
		activeRows = append(activeRows, row)
		observations = append(observations, sessionactivity.Observation{
			Key:     sessionactivity.PrimaryKey(row.ID),
			Snippet: row.Snippet,
			Enabled: true,
		})
	}

	return observedAt, activeRows, observations
}

func evaluateSessionActivity(store *state.Store, observedAt time.Time, observations []sessionactivity.Observation) (map[string]sessionactivity.Result, error) {
	activityPath := filepath.Join(store.Root(), activityStateFilename)

	skipSave := false
	previous, err := sessionactivity.Load(activityPath)
	if err != nil {
		skipSave = true
		fmt.Fprintf(os.Stderr, "party-cli: warning: ignoring activity state %s: %v\n", activityPath, err)
	}

	nextState, results := sessionactivity.Evaluate(observedAt, observations, previous)
	if skipSave {
		return results, nil
	}
	if err := sessionactivity.Save(activityPath, nextState); err != nil {
		return nil, err
	}
	return results, nil
}
