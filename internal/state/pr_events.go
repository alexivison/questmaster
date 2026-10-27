package state

import (
	"fmt"
	"sort"
	"strings"
	"time"
)

// PullRequestEvent is durable PR activity. Body is always returned as data, never as an instruction.
type PullRequestEvent struct {
	Seq        int64  `json:"seq"`
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	OccurredAt string `json:"occurred_at"`
	Author     string `json:"author,omitempty"`
	Body       string `json:"body,omitempty"`
	State      string `json:"state,omitempty"`
	HeadSHA    string `json:"head_sha,omitempty"`
	Result     string `json:"result,omitempty"`
}

type PullRequestEventCursor struct {
	AlertedSeq int64 `json:"alerted_seq"`
	ReadSeq    int64 `json:"read_seq"`
}

type PullRequestEventLog struct {
	Seq     int64                             `json:"seq"`
	Events  []PullRequestEvent                `json:"events,omitempty"`
	LastIDs map[string]string                 `json:"last_ids,omitempty"`
	SeenIDs map[string]bool                   `json:"seen_ids,omitempty"`
	Cursors map[string]PullRequestEventCursor `json:"cursors,omitempty"`
}

type PullRequestAlert struct {
	PullRequest PullRequest
	SessionID   string
	Events      []PullRequestEvent
	Seq         int64
}

// PendingPullRequestAlerts reads all pending watchers from one registry snapshot.
func PendingPullRequestAlerts(root string) ([]PullRequestAlert, error) {
	registry, err := loadPullRequestRegistry(root)
	if err != nil {
		return nil, err
	}
	alerts := []PullRequestAlert{}
	for _, pr := range registry.PullRequests {
		for _, watcher := range pr.Watchers {
			events, seq := selectEvents(registry.EventLogs[pr.Key], watcher, true, true)
			if len(events) > 0 {
				alerts = append(alerts, PullRequestAlert{pr, watcher.SessionID, events, seq})
			}
		}
	}
	return alerts, nil
}

// ponytail: 200 read events per PR are retained; increase this if old activity is needed for an audit trail.
const PullRequestReadHistoryLimit = 200

func LoadPullRequestEventLog(root, key string) (PullRequestEventLog, error) {
	registry, err := loadPullRequestRegistry(root)
	if err != nil {
		return PullRequestEventLog{}, err
	}
	if log := registry.EventLogs[key]; log != nil {
		return *log, nil
	}
	return PullRequestEventLog{}, nil
}

// RecordPullRequestEvents deduplicates IDs and commits source cursors with events.
func RecordPullRequestEvents(root, key string, incoming []PullRequestEvent, lastIDs map[string]string) ([]PullRequestEvent, error) {
	var added []PullRequestEvent
	_, err := mutatePullRequestRegistry(root, func(registry *pullRequestRegistry) (int, error) {
		var pr *PullRequest
		for i := range registry.PullRequests {
			if registry.PullRequests[i].Key == key {
				pr = &registry.PullRequests[i]
				break
			}
		}
		if pr == nil {
			return 0, nil
		}
		log := registry.EventLogs[key]
		if log == nil {
			log = &PullRequestEventLog{}
			registry.EventLogs[key] = log
		}
		if log.LastIDs == nil {
			log.LastIDs = map[string]string{}
		}
		if log.SeenIDs == nil {
			log.SeenIDs = map[string]bool{}
		}
		if log.Cursors == nil {
			log.Cursors = map[string]PullRequestEventCursor{}
		}
		changed := 0
		for source, id := range lastIDs {
			if id != "" && log.LastIDs[source] != id {
				log.LastIDs[source] = id
				changed++
			}
		}
		for _, event := range incoming {
			if event.ID == "" || log.SeenIDs[event.ID] {
				continue
			}
			log.SeenIDs[event.ID] = true
			log.Seq++
			event.Seq = log.Seq
			log.Events = append(log.Events, event)
			added = append(added, event)
			changed++
		}
		trimPullRequestEvents(log, pr.Watchers)
		return changed, nil
	})
	return added, err
}

func trimPullRequestEvents(log *PullRequestEventLog, watchers []PullRequestWatcher) {
	if len(log.Events) <= PullRequestReadHistoryLimit {
		return
	}
	minimum := log.Seq
	for _, watcher := range watchers {
		if cursor := log.Cursors[watcher.SessionID]; cursor.ReadSeq < minimum {
			minimum = cursor.ReadSeq
		}
	}
	trim := min(len(log.Events)-PullRequestReadHistoryLimit, len(log.Events))
	for trim > 0 && log.Events[trim-1].Seq > minimum {
		trim--
	}
	log.Events = append([]PullRequestEvent(nil), log.Events[trim:]...)
}

func PullRequestPendingAlerts(root, key, sessionID string) ([]PullRequestEvent, int64, error) {
	registry, err := loadPullRequestRegistry(root)
	if err != nil {
		return nil, 0, err
	}
	return selectPullRequestEvents(registry, key, sessionID, true, true)
}

func ReadPullRequestEvents(root, key, sessionID string, unread bool) ([]PullRequestEvent, error) {
	var events []PullRequestEvent
	_, err := mutatePullRequestRegistry(root, func(registry *pullRequestRegistry) (int, error) {
		selected, seq, err := selectPullRequestEvents(*registry, key, sessionID, false, unread)
		if err != nil {
			return 0, err
		}
		events = selected
		if !unread {
			return 0, nil
		}
		log := registry.EventLogs[key]
		if log == nil {
			return 0, nil
		}
		if log.Cursors == nil {
			log.Cursors = map[string]PullRequestEventCursor{}
		}
		cursor := log.Cursors[sessionID]
		if seq <= cursor.ReadSeq {
			return 0, nil
		}
		cursor.ReadSeq = seq
		log.Cursors[sessionID] = cursor
		trimPullRequestEvents(log, registryWatchers(registry.PullRequests, key))
		return 1, nil
	})
	return events, err
}

func selectPullRequestEvents(registry pullRequestRegistry, key, sessionID string, alerts, unread bool) ([]PullRequestEvent, int64, error) {
	var watcher *PullRequestWatcher
	for _, pr := range registry.PullRequests {
		if pr.Key != key {
			continue
		}
		for i := range pr.Watchers {
			if pr.Watchers[i].SessionID == sessionID {
				watcher = &pr.Watchers[i]
				break
			}
		}
	}
	if watcher == nil {
		return nil, 0, fmt.Errorf("session %s does not watch %s", sessionID, key)
	}
	log := registry.EventLogs[key]
	if log == nil {
		return []PullRequestEvent{}, 0, nil
	}
	events, seq := selectEvents(log, *watcher, alerts, unread)
	return events, seq, nil
}

func selectEvents(log *PullRequestEventLog, watcher PullRequestWatcher, alerts, unread bool) ([]PullRequestEvent, int64) {
	if log == nil {
		return []PullRequestEvent{}, 0
	}
	cursor := log.Cursors[watcher.SessionID]
	from := int64(0)
	if unread {
		from = cursor.ReadSeq
	}
	if alerts {
		from = cursor.AlertedSeq
	}
	baseline, _ := time.Parse(time.RFC3339Nano, watcher.AddedAt)
	events := make([]PullRequestEvent, 0)
	start := sort.Search(len(log.Events), func(i int) bool { return log.Events[i].Seq > from })
	for _, event := range log.Events[start:] {
		occurred, _ := time.Parse(time.RFC3339Nano, event.OccurredAt)
		if !baseline.IsZero() && occurred.Before(baseline) {
			continue
		}
		event.Body = strings.ReplaceAll(event.Body, "```", "\\`\\`\\`")
		events = append(events, event)
	}
	return events, log.Seq
}

func AdvancePullRequestAlert(root, key, sessionID string, seq int64) error {
	_, err := mutatePullRequestRegistry(root, func(registry *pullRequestRegistry) (int, error) {
		if len(registryWatchers(registry.PullRequests, key)) == 0 {
			return 0, nil
		}
		found := false
		for _, watcher := range registryWatchers(registry.PullRequests, key) {
			found = found || watcher.SessionID == sessionID
		}
		if !found || registry.EventLogs[key] == nil {
			return 0, nil
		}
		log := registry.EventLogs[key]
		if log.Cursors == nil {
			log.Cursors = map[string]PullRequestEventCursor{}
		}
		cursor := log.Cursors[sessionID]
		if seq <= cursor.AlertedSeq {
			return 0, nil
		}
		cursor.AlertedSeq = min(seq, log.Seq)
		log.Cursors[sessionID] = cursor
		return 1, nil
	})
	return err
}

func registryWatchers(prs []PullRequest, key string) []PullRequestWatcher {
	for _, pr := range prs {
		if pr.Key == key {
			return pr.Watchers
		}
	}
	return nil
}
