package prstatus

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

// Job is the single polling owner under the daemon's jobs.lock.
type refreshWaiter struct {
	ctx   context.Context
	reply chan HostResult
}

type Job struct {
	Root             string
	Tmux             *tmux.Client
	TmuxRouter       *tmuxroute.Router
	RunGH            Runner
	RunREST          Runner
	SendAlert        func(context.Context, string, string) (message.Delivery, error)
	Now              func() time.Time
	Tick             <-chan time.Time // injected by tests; production ticks every five seconds
	mu               sync.Mutex
	forced           map[string]bool
	waiters          map[string][]refreshWaiter
	signal           chan struct{}
	runStop          <-chan struct{}
	next             map[string]time.Time
	blocked          map[string]time.Time
	last             map[string]HostResult
	failures         map[string]int
	done             map[string]time.Time
	seen             map[string]bool
	alertErrorLogged map[string]time.Time
}

func NewJob(root string, client *tmux.Client, run Runner, routers ...*tmuxroute.Router) *Job {
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
	return &Job{Root: root, Tmux: client, TmuxRouter: router, RunGH: run, RunREST: GHREST, Now: time.Now, forced: map[string]bool{}, waiters: map[string][]refreshWaiter{}, signal: make(chan struct{}, 1), next: map[string]time.Time{}, blocked: map[string]time.Time{}, last: map[string]HostResult{}, failures: map[string]int{}, done: map[string]time.Time{}, seen: map[string]bool{}, alertErrorLogged: map[string]time.Time{}}
}
func (j *Job) liveIDs(ctx context.Context, ids []string) (map[string]bool, error) {
	if j.TmuxRouter == nil {
		return nil, fmt.Errorf("tmux router is required for PR polling")
	}
	inv := j.TmuxRouter.Inventory(ctx)
	for _, server := range inv.Servers {
		if server.Outcome == tmuxroute.Unavailable {
			return nil, fmt.Errorf("tmux server %s unavailable: %s", server.Label, server.Error)
		}
	}
	observed := make(map[string]bool, len(inv.Rows))
	for _, row := range inv.Rows {
		observed[row.Label+"\x00"+row.ID] = true
	}
	store := state.OpenStore(j.Root)
	live := make(map[string]bool, len(ids))
	seen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		manifest, err := store.Read(id)
		if err != nil {
			continue
		}
		if manifest.NeedsTmuxBackfill() {
			continue
		}
		handle, err := j.TmuxRouter.Route(manifest)
		if err != nil {
			return nil, err
		}
		if observed[handle.Label()+"\x00"+manifest.SessionID] {
			live[manifest.SessionID] = true
		}
	}
	return live, nil
}
func (*Job) Name() string { return "pr-status" }

func (j *Job) HasWork() bool {
	prs, _, err := j.live(context.Background())
	if err != nil || len(prs) > 0 {
		return true // a transient tmux error must not idle out monitoring
	}
	alerts, err := state.PendingPullRequestAlerts(j.Root)
	if err != nil {
		return true
	}
	if len(alerts) == 0 {
		return false
	}
	ids := make([]string, 0, len(alerts))
	for _, alert := range alerts {
		ids = append(ids, alert.SessionID)
	}
	live, err := j.liveIDs(context.Background(), ids)
	if err != nil {
		return true
	}
	for _, alert := range alerts {
		if live[alert.SessionID] {
			return true
		}
	}
	return false
}

func (j *Job) live(ctx context.Context) ([]state.PullRequest, map[string]state.PullRequestStatus, error) {
	prs, err := state.LoadPullRequests(j.Root)
	if err != nil {
		return nil, nil, err
	}
	if len(prs) == 0 {
		return nil, nil, nil
	}
	ids := []string{}
	for _, pr := range prs {
		for _, watcher := range pr.Watchers {
			ids = append(ids, watcher.SessionID)
		}
	}
	live, err := j.liveIDs(ctx, ids)
	if err != nil {
		return nil, nil, err
	}
	statuses, err := state.LoadPullRequestStatuses(j.Root)
	if err != nil {
		return nil, nil, err
	}
	result := make([]state.PullRequest, 0, len(prs))
	for _, pr := range prs {
		if statuses[pr.Key].State == "merged" {
			continue
		}
		hasLiveWatcher := false
		for _, watcher := range pr.Watchers {
			if live[watcher.SessionID] {
				hasLiveWatcher = true
				break
			}
		}
		if hasLiveWatcher {
			result = append(result, pr)
		}
	}
	return result, statuses, nil
}

func (j *Job) Notify(keys []string) {
	j.mu.Lock()
	for host := range hostsForKeys(keys) {
		j.forced[host] = true
	}
	j.mu.Unlock()
	select {
	case j.signal <- struct{}{}:
	default:
	}
}
func (j *Job) Refresh(ctx context.Context, keys []string) (map[string]HostResult, error) {
	hosts := hostsForKeys(keys)
	if len(hosts) == 0 {
		return map[string]HostResult{}, nil
	}
	replies := make(map[string]chan HostResult, len(hosts))
	j.mu.Lock()
	stop := j.runStop
	for host := range hosts {
		ch := make(chan HostResult, 1)
		replies[host] = ch
		j.forced[host] = true
		j.waiters[host] = append(j.waiters[host], refreshWaiter{ctx, ch})
	}
	j.mu.Unlock()
	defer func() {
		j.mu.Lock()
		defer j.mu.Unlock()
		for host, ch := range replies {
			for i, waiter := range j.waiters[host] {
				if waiter.reply == ch {
					j.waiters[host] = append(j.waiters[host][:i], j.waiters[host][i+1:]...)
					break
				}
			}
		}
	}()
	select {
	case j.signal <- struct{}{}:
	default:
	}
	result := make(map[string]HostResult, len(replies))
	for host, ch := range replies {
		select {
		case value := <-ch:
			result[host] = value
		case <-stop:
			return nil, context.Canceled
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return result, nil
}
func hostsForKeys(keys []string) map[string]bool {
	hosts := map[string]bool{}
	for _, key := range keys {
		if host, _, ok := strings.Cut(key, "/"); ok && host != "" {
			hosts[host] = true
		}
	}
	return hosts
}

func (j *Job) Run(ctx context.Context) error {
	j.mu.Lock()
	j.runStop = ctx.Done()
	j.mu.Unlock()
	defer func() { j.mu.Lock(); j.runStop = nil; j.mu.Unlock() }()
	tick := j.Tick
	if tick == nil {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		tick = ticker.C
	}
	for {
		if err := j.step(ctx); err != nil && ctx.Err() == nil {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-tick:
		case <-j.signal:
		}
	}
}

func (j *Job) step(ctx context.Context) error {
	j.mu.Lock()
	forced := j.forced
	j.forced = map[string]bool{}
	waiters := j.waiters
	j.waiters = map[string][]refreshWaiter{}
	j.mu.Unlock()
	completed := false
	defer func() {
		if completed {
			return
		}
		j.mu.Lock()
		defer j.mu.Unlock()
		for host := range forced {
			j.forced[host] = true
		}
		for host, replies := range waiters {
			for _, reply := range replies {
				if reply.ctx.Err() == nil {
					j.waiters[host] = append(j.waiters[host], reply)
				}
			}
		}
	}()
	prs, statuses, err := j.live(ctx)
	if err != nil {
		return err
	}
	now := j.Now()
	byHost := map[string][]state.PullRequest{}
	for _, pr := range prs {
		byHost[pr.Host] = append(byHost[pr.Host], pr)
	}
	// A completed agent turn can mean a push; read hook files even without app subscribers.
	doneEvents := map[string]bool{}
	for _, pr := range prs {
		for _, watcher := range pr.Watchers {
			if _, seen := doneEvents[watcher.SessionID]; seen {
				continue
			}
			ss, err := state.LoadSessionStateAt(j.Root, watcher.SessionID)
			if err != nil {
				continue
			}
			var doneAt time.Time
			if ss != nil {
				if pane, ok := ss.Panes["agent"]; ok && pane.State == "done" {
					doneAt = pane.LastEvent
				}
			}
			prior := j.done[watcher.SessionID]
			doneEvents[watcher.SessionID] = j.seen[watcher.SessionID] && !doneAt.IsZero() && !doneAt.Equal(prior)
			j.done[watcher.SessionID] = doneAt
			j.seen[watcher.SessionID] = true
		}
	}
	for _, pr := range prs {
		for _, watcher := range pr.Watchers {
			if doneEvents[watcher.SessionID] {
				forced[pr.Host] = true
			}
		}
	}
	for id := range j.done {
		if _, ok := doneEvents[id]; !ok {
			delete(j.done, id)
			delete(j.seen, id)
		}
	}
	due := make([]state.PullRequest, 0, len(prs))
	fetched := map[string]bool{}
	for host, group := range byHost {
		if now.Before(j.next[host]) && !forced[host] {
			continue
		}
		// A wake never bypasses a rate-limit or error backoff.
		if now.Before(j.blocked[host]) {
			continue
		}
		due = append(due, group...)
		fetched[host] = true
	}
	result := Result{Hosts: map[string]HostResult{}}
	if len(due) > 0 {
		result = Fetch(ctx, due, j.RunGH, now)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		failed := map[string]bool{}
		limited := map[string]bool{}
		for host, item := range result.Hosts {
			failed[host] = item.Error != ""
			limited[host] = item.BackoffUntil != ""
		}
		for _, pr := range due {
			current, ok := result.Statuses[pr.Key]
			if !ok || failed[pr.Host] || current.InaccessibleReason != "" {
				continue
			}
			prior, hadPrior := statuses[pr.Key]
			if current.UpdatedAt == prior.UpdatedAt && current.Comments == prior.Comments && current.Review == prior.Review && current.State == prior.State && current.HeadSHA == prior.HeadSHA && current.CI == prior.CI && !ciRerunFinished(prior, current) && !ciSettled(prior, current) {
				continue
			}
			if limited[pr.Host] {
				delete(result.Statuses, pr.Key)
				continue
			}
			var baseline time.Time
			for _, watcher := range pr.Watchers {
				if added, err := time.Parse(time.RFC3339Nano, watcher.AddedAt); err == nil && (baseline.IsZero() || added.Before(baseline)) {
					baseline = added
				}
			}
			updated, _ := time.Parse(time.RFC3339Nano, current.UpdatedAt)
			stateAt, _ := time.Parse(time.RFC3339Nano, result.StateAt[pr.Key])
			if baseline.After(now) {
				continue
			}
			if !hadPrior && !baseline.IsZero() && updated.Before(baseline) && stateAt.Before(baseline) && current.CI != "success" && current.CI != "failure" {
				continue
			}
			log, err := state.LoadPullRequestEventLog(j.Root, pr.Key)
			if err != nil {
				return err
			}
			events, ids, detail := fetchDetails(ctx, pr, prior, current, hadPrior, result.StateAt[pr.Key], log, j.RunGH, j.RunREST, now, result.Viewers[pr.Host])
			if detail.Error != "" {
				detail.CheckedAt = result.Hosts[pr.Host].CheckedAt
				result.Hosts[pr.Host] = detail
				failed[pr.Host] = true
				delete(result.Statuses, pr.Key)
				continue
			}
			if detail.RateLimit != nil || detail.BackoffUntil != "" {
				host := result.Hosts[pr.Host]
				if detail.RateLimit != nil {
					host.RateLimit = mergeRateLimit(host.RateLimit, detail.RateLimit)
				}
				if detail.BackoffUntil != "" {
					host.BackoffUntil = detail.BackoffUntil
				}
				result.Hosts[pr.Host] = host
				limited[pr.Host] = host.BackoffUntil != ""
			}
			if _, err := state.RecordPullRequestEvents(j.Root, pr.Key, events, ids); err != nil {
				return err
			}
		}
		if err := state.SavePullRequestStatuses(j.Root, result.Statuses, failed); err != nil {
			return err
		}
		for host, group := range byHost {
			if !fetched[host] {
				continue
			}
			item := result.Hosts[host]
			j.last[host] = item
			until, _ := time.Parse(time.RFC3339, item.BackoffUntil)
			j.blocked[host] = time.Time{}
			if item.Error != "" {
				j.next[host] = now
				if until.After(now) {
					j.blocked[host] = until
				} else {
					j.failures[host]++
					delay := 5 * time.Second << min(j.failures[host]-1, 6)
					if delay > 5*time.Minute {
						delay = 5 * time.Minute
					}
					j.blocked[host] = now.Add(delay)
				}
			} else {
				j.failures[host] = 0
				cadence := 60 * time.Second
				for _, pr := range group {
					status, ok := result.Statuses[pr.Key]
					if !ok {
						status = statuses[pr.Key]
					}
					updated, _ := time.Parse(time.RFC3339, status.UpdatedAt)
					if status.CI == "pending" || (!updated.IsZero() && now.Sub(updated) < 10*time.Minute) {
						cadence = 20 * time.Second
						break
					}
				}
				j.next[host] = now.Add(cadence)
				if until.After(now) {
					j.blocked[host] = until
				}
			}
		}
	}
	j.mu.Lock()
	for host := range forced {
		if !fetched[host] && len(byHost[host]) > 0 {
			j.forced[host] = true
			if now.Before(j.blocked[host]) {
				item := j.last[host]
				item.CheckedAt = ""
				item.BackoffUntil = j.blocked[host].UTC().Format(time.RFC3339)
				for _, reply := range waiters[host] {
					if reply.ctx.Err() == nil {
						reply.reply <- item
					}
				}
				continue
			}
			for _, reply := range waiters[host] {
				if reply.ctx.Err() == nil {
					j.waiters[host] = append(j.waiters[host], reply)
				}
			}
			continue
		}
		for _, waiter := range waiters[host] {
			if waiter.ctx.Err() == nil {
				waiter.reply <- result.Hosts[host]
			}
		}
	}
	j.mu.Unlock()
	if err := j.deliverPending(ctx); err != nil {
		return err
	}
	completed = true
	return nil
}

func (j *Job) deliverPending(ctx context.Context) error {
	alerts, err := state.PendingPullRequestAlerts(j.Root)
	if err != nil {
		return err
	}
	if len(alerts) == 0 {
		clear(j.alertErrorLogged)
		return nil
	}
	ids := make([]string, 0, len(alerts))
	for _, alert := range alerts {
		ids = append(ids, alert.SessionID)
	}
	live, err := j.liveIDs(ctx, ids)
	if err != nil {
		return err
	}
	send := j.SendAlert
	if send == nil {
		send = message.NewServiceWithRouter(state.OpenStore(j.Root), j.TmuxRouter).Notify
	}
	active := make(map[string]bool, len(alerts))
	var statuses map[string]state.PullRequestStatus
	for _, alert := range alerts {
		if !live[alert.SessionID] {
			continue
		}
		key := alert.PullRequest.Key + "\x00" + alert.SessionID
		active[key] = true
		events := alert.Events
		if hasCIEvent(events) {
			if statuses == nil {
				statuses, err = state.LoadPullRequestStatuses(j.Root)
				if err != nil {
					return err
				}
			}
			head := statuses[alert.PullRequest.Key].HeadSHA
			if !j.Now().Before(j.blocked[alert.PullRequest.Host]) && j.RunGH != nil {
				checked, result := checkHead(ctx, alert.PullRequest, j.RunGH, j.Now())
				if result.BackoffUntil != "" {
					if until, parseErr := time.Parse(time.RFC3339, result.BackoffUntil); parseErr == nil {
						j.blocked[alert.PullRequest.Host] = until
					}
				}
				if result.RateLimit != nil {
					last := j.last[alert.PullRequest.Host]
					last.RateLimit = mergeRateLimit(last.RateLimit, result.RateLimit)
					last.BackoffUntil = result.BackoffUntil
					j.last[alert.PullRequest.Host] = last
				}
				if checked != "" {
					head = checked
				}
			}
			events = currentHeadEvents(events, head)
			if len(events) == 0 {
				delete(j.alertErrorLogged, key)
				if err := state.AdvancePullRequestAlert(j.Root, alert.PullRequest.Key, alert.SessionID, alert.Seq); err != nil {
					return err
				}
				continue
			}
		}
		text := alertText(alert.PullRequest, events)
		delivery, err := send(ctx, alert.SessionID, text)
		if err != nil {
			if ctx.Err() == nil && j.Now().Sub(j.alertErrorLogged[key]) >= time.Minute {
				fmt.Fprintf(os.Stderr, "daemon job pr-status: alert %s to %s: %v\n", alert.PullRequest.Key, alert.SessionID, err)
				j.alertErrorLogged[key] = j.Now()
			}
			continue // transport failures are retried on the next tick
		}
		if delivery != "" {
			delete(j.alertErrorLogged, key)
			if err := state.AdvancePullRequestAlert(j.Root, alert.PullRequest.Key, alert.SessionID, alert.Seq); err != nil {
				return err
			}
		}
	}
	for key := range j.alertErrorLogged {
		if !active[key] {
			delete(j.alertErrorLogged, key)
		}
	}
	return nil
}

func hasCIEvent(events []state.PullRequestEvent) bool {
	for _, event := range events {
		if event.Kind == "ci" {
			return true
		}
	}
	return false
}

func currentHeadEvents(events []state.PullRequestEvent, head string) []state.PullRequestEvent {
	kept := make([]state.PullRequestEvent, 0, len(events))
	for _, event := range events {
		if event.Kind != "ci" || event.HeadSHA == "" || head == "" || event.HeadSHA == head {
			kept = append(kept, event)
		}
	}
	return kept
}

var _ interface {
	Name() string
	Run(context.Context) error
	HasWork() bool
} = (*Job)(nil)
