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
	Topics   []string
	QuestIDs []string
	Clock    bool
}

// Affects reports whether the change should wake a subscriber for topic.
func (c Change) Affects(topic, subscribedQuestID string) bool {
	if len(c.Topics) == 0 {
		return false
	}
	if !contains(c.Topics, topic) {
		return false
	}
	if topic != topicQuest || len(c.QuestIDs) == 0 || subscribedQuestID == "" {
		return true
	}
	return contains(c.QuestIDs, subscribedQuestID)
}

func allTopicsChange() Change {
	return Change{Topics: []string{topicBoard, topicTracker, topicQuest, topicItems}}
}

func topicChange(topics ...string) Change {
	return Change{Topics: dedupe(topics)}
}

func questChange(id string, topics ...string) Change {
	c := topicChange(topics...)
	if id != "" {
		c.QuestIDs = []string{id}
	}
	return c
}

func sessionChange(ids []string) Change {
	questIDs := dedupe(ids)
	topics := []string{topicTracker}
	if len(questIDs) > 0 {
		topics = append(topics, topicBoard, topicQuest)
	}
	return Change{
		Topics:   topics,
		QuestIDs: questIDs,
	}
}

func clockChange() Change {
	return Change{
		Topics: []string{topicBoard, topicTracker, topicQuest},
		Clock:  true,
	}
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

	stateRoot  string
	itemsDir   string
	questDir   string
	runtimeDir string

	mu          sync.Mutex
	subscribers map[chan Change]struct{}
	watched     map[string]struct{}

	sessionQuestIDs map[string]string
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
	sessionQuestIDs := snapshotter.SessionQuestIndex()
	if sessionQuestIDs == nil {
		sessionQuestIDs = map[string]string{}
	}
	source := &FileChangeSource{
		snapshotter:     snapshotter,
		watcher:         watcher,
		cancel:          cancel,
		stateRoot:       filepath.Clean(snapshotter.StateRoot()),
		itemsDir:        filepath.Clean(filepath.Join(snapshotter.StateRoot(), "items")),
		questDir:        filepath.Clean(snapshotter.QuestDir()),
		runtimeDir:      filepath.Clean(snapshotter.RuntimeDir()),
		subscribers:     map[chan Change]struct{}{},
		watched:         map[string]struct{}{},
		sessionQuestIDs: sessionQuestIDs,
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
	for _, dir := range []string{s.stateRoot, s.itemsDir, s.questDir, s.runtimeDir} {
		if dir == "" || dir == "." {
			continue
		}
		if err := s.watchDir(dir); err != nil {
			return err
		}
	}
	if s.stateRoot == "" || s.stateRoot == "." {
		return nil
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
	if err := os.MkdirAll(dir, 0o755); err != nil {
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

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticks:
			s.publish(clockChange())
		case event, ok := <-s.watcher.Events:
			if !ok {
				return
			}
			if event.Op&fsnotify.Chmod == event.Op {
				continue
			}
			for _, change := range s.handleEvent(event) {
				s.publish(change)
			}
		case _, ok := <-s.watcher.Errors:
			if !ok {
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

	if s.questDir != "" && s.questDir != "." && filepath.Dir(path) == s.questDir && strings.HasSuffix(base, ".html") {
		id := strings.TrimSuffix(base, ".html")
		return questChange(id, topicBoard, topicQuest)
	}
	if s.runtimeDir != "" && s.runtimeDir != "." && filepath.Dir(path) == s.runtimeDir && strings.HasSuffix(base, ".json") {
		id := strings.TrimSuffix(base, ".json")
		return questChange(id, topicBoard, topicQuest)
	}
	if s.stateRoot == "" || s.stateRoot == "." || !isWithin(path, s.stateRoot) {
		return Change{}
	}
	if s.itemsDir != "" && s.itemsDir != "." && filepath.Dir(path) == s.itemsDir && strings.HasSuffix(base, ".json") {
		return topicChange(topicItems)
	}
	if filepath.Dir(path) == s.stateRoot {
		if base == state.RepoColorsFile {
			return topicChange(topicTracker)
		}
		if strings.HasSuffix(base, ".json") {
			sessionID := strings.TrimSuffix(base, ".json")
			if state.IsValidSessionID(sessionID) {
				s.watchSessionDir(sessionID)
				return sessionChange(s.refreshSessionQuestIDs(sessionID))
			}
		}
		if state.IsValidSessionID(base) {
			return sessionChange(s.refreshSessionQuestIDs(base))
		}
		return Change{}
	}

	sessionID := filepath.Base(filepath.Dir(path))
	if !state.IsValidSessionID(sessionID) {
		return Change{}
	}
	switch base {
	case "state.json":
		return sessionChange(s.refreshSessionQuestIDs(sessionID))
	case "state.jsonl", "state.jsonl.1":
		return Change{}
	default:
		return Change{}
	}
}

func ignoredWatchFile(base string) bool {
	return strings.HasSuffix(base, ".tmp") ||
		strings.HasSuffix(base, ".lock") ||
		strings.HasPrefix(base, ".")
}

func (s *FileChangeSource) refreshSessionQuestIDs(sessionID string) []string {
	oldID := s.sessionQuestIDs[sessionID]
	newID := s.snapshotter.SessionQuestID(sessionID)
	if newID == "" {
		delete(s.sessionQuestIDs, sessionID)
	} else {
		s.sessionQuestIDs[sessionID] = newID
	}
	return dedupe([]string{oldID, newID})
}

func (s *FileChangeSource) publish(change Change) {
	if len(change.Topics) == 0 {
		return
	}
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
