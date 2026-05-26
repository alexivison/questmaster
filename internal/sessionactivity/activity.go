// Package sessionactivity resolves per-session tracker activity from the
// authoritative hook-driven state.json. The legacy FNV snippet-hash detector
// is gone; State, Activity, and LastKind come from PaneState now.
package sessionactivity

import (
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

// Observation is one tracker-row activity observation. SessionID drives
// the state.json read.
type Observation struct {
	Key       string
	SessionID string
	Enabled   bool
}

// Result is the renderer-visible activity result for one observation
// key. State is one of working|blocked|done|idle|starting|stopped|unknown.
// WorkingSince is non-zero only while State == "working" and timestamps
// the moment the session entered the working state.
type Result struct {
	State        string
	Activity     string
	LastKind     string
	LastEvent    time.Time
	WorkingSince time.Time
}

// PrimaryKey namespaces a session's primary-pane activity key. Kept for
// callers that index results by the same legacy key shape.
func PrimaryKey(sessionID string) string {
	return sessionID + "\x00primary"
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
		results[obs.Key] = resolve(obs)
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

func resolve(obs Observation) Result {
	return loadResult(obs.SessionID)
}

func loadResult(sessionID string) Result {
	if sessionID == "" {
		return Result{State: "unknown"}
	}
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil {
		return Result{State: "unknown"}
	}
	p, ok := ss.Panes["primary"]
	if !ok {
		return Result{State: "unknown"}
	}
	stateName := p.State
	if stateName == "" {
		stateName = "unknown"
	}
	return Result{
		State:        stateName,
		Activity:     normalizeStartingActivity(stateName, p.Activity),
		LastKind:     p.LastKind,
		LastEvent:    p.LastEvent,
		WorkingSince: normalizeWorkingSince(stateName, p.WorkingSince, p.LastEvent),
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
