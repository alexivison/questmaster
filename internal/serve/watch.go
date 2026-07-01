//go:build linux || darwin

package serve

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/fsnotify/fsnotify"
)

// Change is a topic-level invalidation produced by serve's file watcher or by
// the serve-side clock for elapsed/runtime fields. It names the smallest
// existing wire surfaces that need to be re-snapshotted; the payload shape
// remains the existing topic response.
type Change struct {
	Topics     []string
	SessionIDs []string
	Clock      bool
	// BroadTracker marks a session-agnostic tracker change (e.g. a repo-colors
	// edit) that must rebuild the full tracker snapshot. It survives coalescing
	// so a broad change merged with per-session changes inside the debounce
	// window is not silently demoted to a per-session delta.
	BroadTracker bool
}

// Affects reports whether the change should wake a subscriber for topic.
func (c Change) Affects(topic string) bool {
	if len(c.Topics) == 0 {
		return false
	}
	return contains(c.Topics, topic)
}

func allTopicsChange() Change {
	return Change{Topics: []string{topicTracker}}
}

func topicChange(topics ...string) Change {
	return Change{Topics: dedupe(topics)}
}

func sessionChange() Change {
	return Change{Topics: []string{topicTracker}}
}

func clockChange() Change {
	return Change{Topics: []string{topicTracker}, Clock: true}
}

// ChangeSource publishes file-watch and clock invalidations to subscribers.
type ChangeSource interface {
	Subscribe(context.Context) (<-chan Change, func())
	Close() error
}

// FileChangeSource watches the durable qm files that feed serve's read models.
// It does not own state; it only turns filesystem events into topic
// invalidations.
type FileChangeSource struct {
	snapshotter *Snapshotter
	watcher     *fsnotify.Watcher
	cancel      context.CancelFunc
	once        sync.Once
	wg          sync.WaitGroup

	stateRoot string

	mu          sync.Mutex
	subscribers map[chan Change]struct{}
	watched     map[string]struct{}
}

// NewFileChangeSource creates and starts the serve file watcher. clockInterval
// drives only elapsed/runtime clock fields; state changes are watcher-driven.
func NewFileChangeSource(ctx context.Context, snapshotter *Snapshotter, clockInterval time.Duration) (*FileChangeSource, error) {
	if snapshotter == nil {
		snapshotter = NewSnapshotter(nil, nil, nil)
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("create file watcher: %w", err)
	}
	ctx, cancel := context.WithCancel(ctx)
	source := &FileChangeSource{
		snapshotter: snapshotter,
		watcher:     watcher,
		cancel:      cancel,
		stateRoot:   filepath.Clean(snapshotter.StateRoot()),
		subscribers: map[chan Change]struct{}{},
		watched:     map[string]struct{}{},
	}
	if err := source.addInitialWatches(); err != nil {
		watcher.Close() //nolint:errcheck
		cancel()
		return nil, err
	}
	source.wg.Add(1)
	go source.run(ctx, clockInterval)
	return source, nil
}

func (s *FileChangeSource) Subscribe(ctx context.Context) (<-chan Change, func()) {
	ch := make(chan Change, 32)
	var once sync.Once
	unsubscribe := func() {
		once.Do(func() {
			s.mu.Lock()
			delete(s.subscribers, ch)
			close(ch)
			s.mu.Unlock()
		})
	}

	s.mu.Lock()
	s.subscribers[ch] = struct{}{}
	s.mu.Unlock()

	go func() {
		<-ctx.Done()
		unsubscribe()
	}()
	return ch, unsubscribe
}

func (s *FileChangeSource) Close() error {
	var err error
	s.once.Do(func() {
		s.cancel()
		err = s.watcher.Close()
		s.wg.Wait()

		s.mu.Lock()
		for ch := range s.subscribers {
			delete(s.subscribers, ch)
		}
		s.mu.Unlock()
	})
	return err
}

func (s *FileChangeSource) addInitialWatches() error {
	if s.stateRoot == "" || s.stateRoot == "." {
		return nil
	}
	if err := s.watchDir(s.stateRoot); err != nil {
		return err
	}
	entries, err := os.ReadDir(s.stateRoot)
	if err != nil {
		return fmt.Errorf("read state root for watches: %w", err)
	}
	for _, entry := range entries {
		if !entry.IsDir() || !state.IsValidSessionID(entry.Name()) {
			continue
		}
		if err := s.watchDir(filepath.Join(s.stateRoot, entry.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (s *FileChangeSource) watchDir(dir string) error {
	dir = filepath.Clean(dir)
	if dir == "" || dir == "." {
		return nil
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create watch dir %s: %w", dir, err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.watched[dir]; ok {
		return nil
	}
	if err := s.watcher.Add(dir); err != nil {
		return fmt.Errorf("watch %s: %w", dir, err)
	}
	s.watched[dir] = struct{}{}
	return nil
}

func (s *FileChangeSource) run(ctx context.Context, clockInterval time.Duration) {
	defer s.wg.Done()

	var ticker *time.Ticker
	var ticks <-chan time.Time
	if clockInterval > 0 {
		ticker = time.NewTicker(clockInterval)
		ticks = ticker.C
		defer ticker.Stop()
	}

	var pending Change
	var debounce *time.Timer
	var debounceC <-chan time.Time
	var maxWait *time.Timer
	var maxWaitC <-chan time.Time
	resetTimer := func(timer *time.Timer, d time.Duration) {
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(d)
	}
	stopTimer := func(timer *time.Timer) {
		if timer == nil {
			return
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
	}
	queue := func(change Change) {
		if len(change.Topics) == 0 {
			return
		}
		pending = mergeChanges(pending, change)
		if debounce == nil {
			debounce = time.NewTimer(watchDebounceWindow)
			debounceC = debounce.C
			maxWait = time.NewTimer(watchDebounceMaxWait)
			maxWaitC = maxWait.C
			return
		}
		resetTimer(debounce, watchDebounceWindow)
	}
	flush := func() {
		if len(pending.Topics) > 0 {
			s.publish(pending)
			pending = Change{}
		}
		if debounce != nil {
			stopTimer(debounce)
			debounce = nil
			debounceC = nil
		}
		if maxWait != nil {
			stopTimer(maxWait)
			maxWait = nil
			maxWaitC = nil
		}
	}

	for {
		select {
		case <-ctx.Done():
			flush()
			return
		case <-ticks:
			s.publish(clockChange())
		case <-debounceC:
			flush()
		case <-maxWaitC:
			flush()
		case event, ok := <-s.watcher.Events:
			if !ok {
				flush()
				return
			}
			if event.Op&fsnotify.Chmod == event.Op {
				continue
			}
			for _, change := range s.handleEvent(event) {
				queue(change)
			}
		case _, ok := <-s.watcher.Errors:
			if !ok {
				flush()
				return
			}
		}
	}
}

func (s *FileChangeSource) handleEvent(event fsnotify.Event) []Change {
	path := filepath.Clean(event.Name)
	s.maybeWatchSessionDir(path)
	change := s.classify(path)
	if len(change.Topics) == 0 {
		return nil
	}
	return []Change{change}
}

func (s *FileChangeSource) maybeWatchSessionDir(path string) {
	if s.stateRoot == "" || s.stateRoot == "." || filepath.Dir(path) != s.stateRoot {
		return
	}
	s.watchSessionDir(filepath.Base(path))
}

func (s *FileChangeSource) watchSessionDir(sessionID string) {
	if !state.IsValidSessionID(sessionID) {
		return
	}
	path := filepath.Join(s.stateRoot, sessionID)
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return
	}
	_ = s.watchDir(path)
}

func (s *FileChangeSource) classify(path string) Change {
	base := filepath.Base(path)
	if ignoredWatchFile(base) {
		return Change{}
	}

	if s.stateRoot == "" || s.stateRoot == "." || !isWithin(path, s.stateRoot) {
		return Change{}
	}
	if filepath.Dir(path) == s.stateRoot {
		if base == state.RepoColorsFile {
			change := topicChange(topicTracker)
			change.BroadTracker = true
			return change
		}
		if strings.HasSuffix(base, ".json") {
			sessionID := strings.TrimSuffix(base, ".json")
			if state.IsValidSessionID(sessionID) {
				s.watchSessionDir(sessionID)
				return s.sessionManifestChange(sessionID)
			}
		}
		if state.IsValidSessionID(base) {
			return s.sessionChange(base)
		}
		return Change{}
	}

	sessionID := filepath.Base(filepath.Dir(path))
	if !state.IsValidSessionID(sessionID) {
		return Change{}
	}
	switch base {
	case "state.json", "artifacts.json":
		return s.sessionChange(sessionID)
	case "state.jsonl", "state.jsonl.1":
		return Change{}
	default:
		return Change{}
	}
}

func (s *FileChangeSource) sessionChange(sessionID string) Change {
	change := sessionChange()
	change.SessionIDs = []string{sessionID}
	return change
}

func (s *FileChangeSource) sessionManifestChange(sessionID string) Change {
	change := sessionChange()
	change.SessionIDs = []string{sessionID}
	return change
}

func ignoredWatchFile(base string) bool {
	return strings.HasSuffix(base, ".tmp") ||
		strings.HasSuffix(base, ".lock") ||
		strings.HasPrefix(base, ".")
}

func (s *FileChangeSource) publish(change Change) {
	if len(change.Topics) == 0 {
		return
	}
	// Hold s.mu across the fan-out: unsubscribe() closes subscriber channels
	// under the same lock, so releasing it before sending would let a send race
	// a close and panic ("send on closed channel"). The sends are non-blocking
	// channel ops, so lock-hold stays nanosecond-scale.
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.subscribers {
		select {
		case ch <- change:
		default:
			// Coalesce a backed-up client to a broad catch-up invalidation
			// without blocking the daemon's watcher loop.
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- allTopicsChange():
			default:
			}
		}
	}
}

func isWithin(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

func contains(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func dedupe(values []string) []string {
	out := make([]string, 0, len(values))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if value == "" {
			continue
		}
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		out = append(out, value)
	}
	return out
}

const (
	watchDebounceWindow  = 75 * time.Millisecond
	watchDebounceMaxWait = 200 * time.Millisecond
)

func mergeChanges(a, b Change) Change {
	return Change{
		Topics:       dedupe(append(append([]string{}, a.Topics...), b.Topics...)),
		SessionIDs:   dedupe(append(append([]string{}, a.SessionIDs...), b.SessionIDs...)),
		Clock:        a.Clock || b.Clock,
		BroadTracker: a.BroadTracker || b.BroadTracker,
	}
}
