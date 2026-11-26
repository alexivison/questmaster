// Package sessionactivity resolves per-session tracker activity from the
// authoritative hook-driven state.json. The legacy FNV snippet-hash detector
// is gone; State, Activity, and LastKind come from PaneState now.
package sessionactivity

import (
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

// Observation identifies a session, its recorded harness and whether it is live.
type Observation struct {
	Key       string
	SessionID string
	Agent     string
	Enabled   bool
}

// Result is the renderer-visible activity result for one observation
// key. State is one of working|blocked|done|idle|starting|stopped|unknown.
// WorkingSince is non-zero only while State == "working" and timestamps
// the moment the session entered the working state.
type Result struct {
	State            string
	Activity         string
	LastKind         string
	LastEvent        time.Time
	WorkingSince     time.Time
	LastChatAt       time.Time
	LastExchangeKind string
	LastExchangeAt   time.Time
	// ActiveSubagents counts the sub-agents the session has running (Claude reports them; see cmd/hook.go).
	ActiveSubagents int
	Agent           string
	Narration       string
	PiProgress      string
	RunningTool     *state.RunningTool
}

// AgentKey namespaces a session's agent-pane activity key.
func AgentKey(sessionID string) string {
	return sessionID + "\x00agent"
}

// Evaluate resolves authoritative state for each observation by reading
// the per-session state.json. Missing/unreadable state files resolve to
// State="unknown".
func Evaluate(observations []Observation) map[string]Result {
	results := make(map[string]Result, len(observations))
	for _, obs := range observations {
		if obs.Key == "" {
			continue
		}
		if !obs.Enabled {
			results[obs.Key] = Result{State: "stopped"}
			continue
		}
		results[obs.Key] = loadResult(obs.SessionID, obs.Agent)
	}
	return results
}

// Label maps an Evaluate result state plus tmux liveness to a user-facing
// status word.
func Label(state string, alive bool) string {
	switch {
	case state == "stopped":
		return "stopped"
	case state == "unknown" && alive:
		return "active"
	case state != "":
		return state
	case alive:
		return "active"
	default:
		return "stopped"
	}
}

func loadResult(sessionID, agentName string) Result {
	if sessionID == "" {
		return Result{State: "unknown"}
	}
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil {
		return Result{State: "unknown"}
	}
	return FromState(ss, agentName)
}

// FromState resolves the activity for the harness recorded in the manifest.
// Pass an empty name when reading history or when no owner is recorded.
func FromState(ss *state.SessionState, agentName string) Result {
	if ss == nil || (agentName != "" && !agent.IsBuiltin(agentName)) {
		return Result{State: "unknown"}
	}
	p, ok := ss.Panes["agent"]
	if !ok {
		return Result{State: "unknown"}
	}
	stateName := p.State
	if stateName == "" {
		stateName = "unknown"
	}
	var runningTool *state.RunningTool
	var piProgress string
	if stateName == "working" && p.Agent == "pi" {
		piProgress = p.PiProgress
	}
	if stateName != "done" && stateName != "idle" && stateName != "stopped" && len(p.RunningTools) > 0 {
		latest := p.RunningTools[len(p.RunningTools)-1]
		runningTool = &latest
	}
	return Result{
		State:            stateName,
		Activity:         normalizeStartingActivity(stateName, p.Activity),
		LastKind:         p.LastKind,
		LastEvent:        p.LastEvent,
		WorkingSince:     normalizeWorkingSince(stateName, p.WorkingSince, p.LastEvent),
		LastChatAt:       p.LastChatAt,
		LastExchangeKind: p.LastExchangeKind,
		LastExchangeAt:   p.LastExchangeAt,
		ActiveSubagents:  len(p.ActiveSubagents),
		Agent:            p.Agent,
		Narration:        p.Narration,
		PiProgress:       piProgress,
		RunningTool:      runningTool,
	}
}

func normalizeWorkingSince(state string, workingSince, lastEvent time.Time) time.Time {
	if state != "working" {
		return time.Time{}
	}
	if !workingSince.IsZero() {
		return workingSince
	}
	return lastEvent
}

// normalizeStartingActivity replaces the legacy "starting…" activity
// string with "started" so older state.json files (written before the
// hook handlers were updated) render as "started" too. Callers see the
// canonical word regardless of which binary wrote the state file.
func normalizeStartingActivity(state, activity string) string {
	if state == "starting" && activity == "starting…" {
		return "started"
	}
	return activity
}
