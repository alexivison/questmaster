//go:build linux || darwin

// Package runtime derives the render-time runtime of quests in one pass over
// the session scan: which adventurers (attached sessions) are on each quest,
// what each is doing (the hook-observed activity), the armed loop marker, and
// the observed auto-gate results from the sidecar. The board, the tracker,
// and `quest view` all consume this one join, so their pictures of "who is on
// the quest and what are they doing" cannot drift. Derived state only —
// nothing here is ever written back to a quest.
package runtime

import (
	"encoding/json"
	"os"
	"sort"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
)

var loadRuntimeSessionStateAt = state.LoadSessionStateAt

// Snapshot builds the derived runtime for the given quest ids in ONE pass
// over the state root (the per-quest SessionsForQuest scan is O(quests ×
// sessions); a polling board cannot afford that). Sidecar results load per
// quest id whether or not the quest is attached — a recorded verdict outlives
// its session. now stamps Runtime.ObservedAt so renderers can show durations
// and verdict ages without a global clock.
func Snapshot(sidecar *gate.Sidecar, questIDs []string, now time.Time) map[string]quest.Runtime {
	wanted := make(map[string]bool, len(questIDs))
	for _, id := range questIDs {
		wanted[id] = true
	}
	byQuest := scanSessions(wanted)

	out := make(map[string]quest.Runtime, len(questIDs))
	for _, id := range questIDs {
		rt := quest.Runtime{ObservedAt: now}
		adventurers := byQuest[id]
		sort.Slice(adventurers, func(i, j int) bool { return adventurers[i].ID < adventurers[j].ID })
		rt.Adventurers = adventurers
		for _, sr := range adventurers {
			rt.Sessions = append(rt.Sessions, sr.ID)
			// The loop session's agent names the runtime agent; otherwise the
			// first attached agent does (mirrors the original questRuntime).
			if sr.Loop != nil && rt.Loop == nil {
				rt.Loop = sr.Loop
				if sr.Agent != "" {
					rt.Agent = sr.Agent
				}
			}
		}
		if rt.Agent == "" {
			for _, sr := range adventurers {
				if sr.Agent != "" {
					rt.Agent = sr.Agent
					break
				}
			}
		}
		if sidecar != nil {
			if res, err := sidecar.Load(id); err == nil {
				rt.Gates = res.StatusMap()
				rt.GatesAt = res.RanAtMap()
			}
		}
		out[id] = rt
	}
	return out
}

// LoopRuntime maps the advisory loop marker to its render-time view. Shared
// by the quest snapshot and the tracker's per-session rows so the loop label
// (iterations, verdict, phase) is derived in exactly one place.
func LoopRuntime(sessionID string, marker *state.QuestLoopState) *quest.LoopRuntime {
	if marker == nil {
		return nil
	}
	return &quest.LoopRuntime{
		SessionID:   sessionID,
		Iterations:  marker.Iterations,
		LastVerdict: marker.LastVerdict,
		Phase:       marker.Phase,
		Owner:       marker.Owner,
	}
}

// scanSessions reads every session's state.json once and groups the attached
// sessions by quest id. wanted filters the manifest/activity work to the
// quests the caller asked about.
func scanSessions(wanted map[string]bool) map[string][]quest.Adventurer {
	root := state.StateRoot()
	if root == "" {
		return nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	store := state.OpenStore(root)
	byQuest := make(map[string][]quest.Adventurer)
	for _, e := range entries {
		if !e.IsDir() || !state.IsValidSessionID(e.Name()) {
			continue
		}
		sid := e.Name()
		questID, err := loadSessionQuestIDAt(root, sid)
		if err != nil || questID == "" || !wanted[questID] {
			continue
		}
		// root is already resolved; avoid LoadSessionState re-reading the env.
		ss, err := loadRuntimeSessionStateAt(root, sid)
		if err != nil || ss == nil || ss.QuestID == "" || !wanted[ss.QuestID] {
			continue
		}
		byQuest[ss.QuestID] = append(byQuest[ss.QuestID], adventurer(store, sid, ss))
	}
	return byQuest
}

func loadSessionQuestIDAt(root, sid string) (string, error) {
	data, err := os.ReadFile(state.SessionStatePath(root, sid))
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	var header struct {
		QuestID string `json:"quest_id"`
	}
	if err := json.Unmarshal(data, &header); err != nil {
		return "", err
	}
	return header.QuestID, nil
}

// adventurer joins one attached session's primary agent with its hook activity
// (what it is doing right now) and loop marker. The agent comes from the
// session state's primary pane, which carries it once the session is active;
// only when the pane has no agent yet do we read + parse the manifest as a
// fallback (previously every attached session paid that manifest read per scan).
func adventurer(store *state.Store, sid string, ss *state.SessionState) quest.Adventurer {
	sr := quest.Adventurer{ID: sid, Loop: LoopRuntime(sid, ss.QuestLoop)}
	if pane, ok := ss.Panes["primary"]; ok {
		sr.Agent = pane.Agent
	}
	if sr.Agent == "" {
		if m, err := store.Read(sid); err == nil {
			sr.Agent = primaryAgentName(m)
		}
	}
	activity := sessionactivity.FromState(ss)
	sr.State = activity.State
	if !activity.WorkingSince.IsZero() {
		sr.Since = activity.WorkingSince
	} else {
		sr.Since = activity.LastEvent
	}
	return sr
}

func primaryAgentName(m state.Manifest) string {
	for _, spec := range m.Agents {
		if spec.Role == "primary" && spec.Name != "" {
			return spec.Name
		}
	}
	return ""
}
