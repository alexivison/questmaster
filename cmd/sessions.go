package cmd

import (
	"encoding/json"
	"io"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/sessionactivity"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tui"
	"github.com/spf13/cobra"
)

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
sourced from the per-session state.json that hooks write — a session is
reported active=true when its primary pane state is "working", and
active=false otherwise. The session is always emitted regardless of the
active flag, so consumers can render idle sessions too.`,
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
	results := sessionactivity.Evaluate(observedAt, observations)

	rows := make([]sessionsJSONRow, 0, len(activeRows))
	for _, row := range activeRows {
		result := results[sessionactivity.PrimaryKey(row.ID)]
		active := result.State == "working"
		out := sessionsJSONRow{
			PartyID:       row.ID,
			Title:         row.Title,
			SessionType:   row.SessionType,
			ParentSession: row.ParentID,
			PrimaryTool:   row.PrimaryAgent,
			Active:        active,
			Cwd:           row.Cwd,
		}
		if active && !result.LastEvent.IsZero() {
			out.LastChangeMS = result.LastEvent.UnixMilli()
		} else if active {
			out.LastChangeMS = observedAt.UnixMilli()
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
			Key:            sessionactivity.PrimaryKey(row.ID),
			SessionID:      row.ID,
			Enabled:        true,
			ActiveOverride: row.PrimaryActiveOverride,
		})
	}

	return observedAt, activeRows, observations
}
