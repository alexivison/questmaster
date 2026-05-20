// Package sessionactivity resolves per-session tracker activity from the
// authoritative hook-driven state.json that Phase 1 introduced. The FNV
// snippet-hash detector that lived here before Phase 2 is gone; State,
// Activity, and LastKind come from PaneState now.
package sessionactivity

import (
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// StaleThreshold is how long a working/blocked session may go without a
// hook event before the tracker downgrades it to "unknown". Tunable per
// PLAN.md "Deferred to implementation time".
const StaleThreshold = 60 * time.Second

// Observation is one tracker-row activity observation. SessionID drives
// the state.json read.
type Observation struct {
	Key       string
	SessionID string
	Enabled   bool
}

// Result is the renderer-visible activity result for one observation
// key. State is one of working|blocked|done|idle|starting|stopped|unknown.
type Result struct {
	State     string
	Activity  string
	LastKind  string
	Stale     bool
	LastEvent time.Time
}

// PrimaryKey namespaces a session's primary-pane activity key. Kept for
// callers that index results by the same key shape Phase 1 produced.
func PrimaryKey(sessionID string) string {
	return sessionID + "\x00primary"
}

// Evaluate resolves authoritative state for each observation by reading
// the per-session state.json. Missing/unreadable state files resolve to
// State="unknown".
func Evaluate(now time.Time, observations []Observation) map[string]Result {
	results := make(map[string]Result, len(observations))
	for _, obs := range observations {
		if obs.Key == "" {
			continue
		}
		if !obs.Enabled {
			results[obs.Key] = Result{State: "stopped"}
			continue
		}
		results[obs.Key] = resolve(now, obs)
	}
	return results
}

func resolve(now time.Time, obs Observation) Result {
	return loadResult(now, obs.SessionID)
}

func loadResult(now time.Time, sessionID string) Result {
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
	res := Result{
		State:     p.State,
		Activity:  p.Activity,
		LastKind:  p.LastKind,
		LastEvent: p.LastEvent,
	}
	if res.State == "" {
		res.State = "unknown"
	}
	if !p.LastEvent.IsZero() && now.Sub(p.LastEvent) > StaleThreshold && res.State != "idle" && res.State != "stopped" {
		res.Stale = true
		if res.State == "working" {
			res.State = "unknown"
		}
	}
	return res
}
