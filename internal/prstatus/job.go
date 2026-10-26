package prstatus

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// Job is the single polling owner under the daemon's jobs.lock.
type refreshWaiter struct {
	ctx   context.Context
	reply chan HostResult
}

type Job struct {
	Root     string
	Tmux     *tmux.Client
	RunGH    Runner
	Now      func() time.Time
	Tick     <-chan time.Time // injected by tests; production ticks every five seconds
	mu       sync.Mutex
	forced   map[string]bool
	waiters  map[string][]refreshWaiter
	signal   chan struct{}
	runStop  <-chan struct{}
	next     map[string]time.Time
	blocked  map[string]time.Time
	failures map[string]int
	done     map[string]time.Time
	seen     map[string]bool
}

func NewJob(root string, client *tmux.Client, run Runner) *Job {
	return &Job{Root: root, Tmux: client, RunGH: run, Now: time.Now, forced: map[string]bool{}, waiters: map[string][]refreshWaiter{}, signal: make(chan struct{}, 1), next: map[string]time.Time{}, blocked: map[string]time.Time{}, failures: map[string]int{}, done: map[string]time.Time{}, seen: map[string]bool{}}
}
func (*Job) Name() string { return "pr-status" }

func (j *Job) HasWork() bool {
	prs, _, err := j.live(context.Background())
	return err != nil || len(prs) > 0 // a transient tmux error must not idle out monitoring
}

func (j *Job) live(ctx context.Context) ([]state.PullRequest, map[string]state.PullRequestStatus, error) {
	prs, err := state.LoadPullRequests(j.Root)
	if err != nil {
		return nil, nil, err
	}
	if len(prs) == 0 {
		return nil, nil, nil
	}
	sessions, err := j.Tmux.ListSessions(ctx)
	if err != nil {
		return nil, nil, err
	}
	live := make(map[string]bool, len(sessions))
	for _, id := range sessions {
		live[id] = true
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
		watchers := pr.Watchers[:0]
		for _, watcher := range pr.Watchers {
			if live[watcher.SessionID] {
				watchers = append(watchers, watcher)
			}
		}
		if len(watchers) > 0 {
			pr.Watchers = watchers
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
		for host, item := range result.Hosts {
			failed[host] = item.Error != ""
		}
		if err := state.SavePullRequestStatuses(j.Root, result.Statuses, failed); err != nil {
			return err
		}
		for host, group := range byHost {
			if !fetched[host] {
				continue
			}
			item := result.Hosts[host]
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
	completed = true
	return nil
}

var _ interface {
	Name() string
	Run(context.Context) error
	HasWork() bool
} = (*Job)(nil)
