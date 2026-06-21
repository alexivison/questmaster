//go:build linux || darwin

package serve

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	topicBoard      = "board"
	topicTracker    = "tracker"
	topicQuest      = "quest"
	topicItems      = "items"
	topicActiveItem = "active_item"
	topicDirSuggest = "dir_suggest"

	methodPublishActiveItem = "publish_active_item"
)

// Request is one JSON line sent by a client.
type Request struct {
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Topics  []string        `json:"topics,omitempty"`
	QuestID string          `json:"quest_id,omitempty"`
	Data    json.RawMessage `json:"data,omitempty"`
}

// Envelope is one JSON line sent by serve.
type Envelope struct {
	Type  string          `json:"type"`
	ID    json.RawMessage `json:"id,omitempty"`
	OK    *bool           `json:"ok,omitempty"`
	Topic string          `json:"topic,omitempty"`
	Data  any             `json:"data,omitempty"`
	Error string          `json:"error,omitempty"`
}

// Server serves read-only snapshots over a Unix domain socket.
type Server struct {
	SocketPath    string
	Snapshotter   *Snapshotter
	ClockInterval time.Duration

	// Interval is kept as a deprecated alias for ClockInterval so older tests
	// and scripts do not silently switch cadence.
	Interval time.Duration

	ChangeSource ChangeSource

	// MutationRunner is injectable for tests; production re-execs this binary
	// for CLI-owned session lifecycle mutations.
	MutationRunner MutationCommandRunner
	TmuxClient     *tmux.Client
	DirQuerier     picker.DirQuerier
}

// DefaultSocketPath returns the default local socket path for qm serve.
func DefaultSocketPath() string {
	if root := state.StateRoot(); root != "" {
		return filepath.Join(root, "serve.sock")
	}
	return filepath.Join(os.TempDir(), "questmaster-serve.sock")
}

// Serve starts the local socket server and runs until ctx is canceled.
func (s *Server) Serve(ctx context.Context) error {
	path := s.SocketPath
	if path == "" {
		path = DefaultSocketPath()
	}
	if s.Snapshotter == nil {
		// Preserve the legacy zero-value server behavior used by tests and
		// ad-hoc tools; production callers should pass an explicit Snapshotter.
		s.Snapshotter = NewSnapshotter(nil, nil, nil)
	}
	clockInterval := s.ClockInterval
	if clockInterval <= 0 {
		clockInterval = s.Interval
	}
	if clockInterval <= 0 {
		clockInterval = time.Second
	}
	if err := prepareSocket(path); err != nil {
		return err
	}
	changeSource := s.ChangeSource
	if changeSource == nil {
		source, err := NewFileChangeSource(ctx, s.Snapshotter, clockInterval)
		if err != nil {
			return err
		}
		changeSource = source
		defer changeSource.Close() //nolint:errcheck
	}
	activeItems := newActiveItemBroker()

	ln, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()      //nolint:errcheck
		os.Remove(path) //nolint:errcheck
		return fmt.Errorf("restrict socket permissions: %w", err)
	}
	defer os.Remove(path) //nolint:errcheck
	defer ln.Close()      //nolint:errcheck

	go func() {
		<-ctx.Done()
		_ = ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go s.handleConn(ctx, conn, changeSource, activeItems)
	}
}

func prepareSocket(path string) error {
	if path == "" {
		return fmt.Errorf("socket path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat socket: %w", err)
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("socket path exists and is not a socket: %s", path)
	}
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err == nil {
		conn.Close() //nolint:errcheck
		return fmt.Errorf("serve socket already active at %s", path)
	}
	if !ownedByCurrentUID(info) {
		return fmt.Errorf("refusing to remove stale socket not owned by current user: %s", path)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}

func ownedByCurrentUID(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(stat.Uid) == os.Getuid()
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn, changeSource ChangeSource, activeItems *activeItemBroker) {
	defer conn.Close() //nolint:errcheck

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)
	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			return
		}
		if req.Method == methodPublishActiveItem {
			item, err := activeItemFromRequest(req)
			if err != nil {
				_ = writeEnvelope(enc, errorEnvelope(req.ID, err))
				continue
			}
			activeItems.Publish(item)
			if err := s.writeResponse(ctx, enc, req.ID, topicActiveItem, map[string]any{"published": true}); err != nil {
				return
			}
			continue
		}
		if req.Method == "subscribe" {
			if err := s.writeResponse(ctx, enc, req.ID, "subscribe", map[string]any{"subscribed": s.subscribedTopics(req)}); err != nil {
				return
			}
			_ = s.subscribe(ctx, enc, req, changeSource, activeItems)
			return
		}
		if isMutationMethod(req.Method) {
			if err := s.writeMutationResponse(ctx, enc, req); err != nil {
				return
			}
			continue
		}
		if req.Method == topicDirSuggest {
			data, err := s.dirSuggest(req)
			if err != nil {
				_ = writeEnvelope(enc, errorEnvelope(req.ID, err))
				continue
			}
			if err := s.writeResponse(ctx, enc, req.ID, topicDirSuggest, data); err != nil {
				return
			}
			continue
		}
		topic := req.Method
		data, err := s.snapshot(ctx, topic, req.QuestID)
		if err != nil {
			_ = writeEnvelope(enc, errorEnvelope(req.ID, err))
			continue
		}
		if err := s.writeResponse(ctx, enc, req.ID, topic, data); err != nil {
			return
		}
	}
}

func (s *Server) writeResponse(ctx context.Context, enc *json.Encoder, id json.RawMessage, topic string, data any) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}
	return writeEnvelope(enc, Envelope{Type: "response", ID: id, OK: boolPtr(true), Topic: topic, Data: data})
}

func (s *Server) subscribe(ctx context.Context, enc *json.Encoder, req Request, changeSource ChangeSource, activeItems *activeItemBroker) error {
	topics := s.snapshotSubscribeTopics(req)
	last := make(map[string][]byte, len(topics))
	if err := s.pushChanged(ctx, enc, topics, req.QuestID, last, allTopicsChange()); err != nil {
		return err
	}

	// A subscribe request owns the connection until the client closes it or the
	// server context is canceled; handleConn returns immediately after this loop.
	changes, unsubscribe := changeSource.Subscribe(ctx)
	defer unsubscribe()
	activeEvents, unsubscribeActive := activeItems.Subscribe(ctx, subscribesActiveItem(req))
	defer unsubscribeActive()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case change, ok := <-changes:
			if !ok {
				return nil
			}
			if err := s.pushChanged(ctx, enc, topics, req.QuestID, last, change); err != nil {
				return err
			}
		case item, ok := <-activeEvents:
			if !ok {
				activeEvents = nil
				continue
			}
			if err := writeEnvelope(enc, Envelope{Type: "event", Topic: topicActiveItem, Data: item}); err != nil {
				return err
			}
		}
	}
}

func (s *Server) pushChanged(ctx context.Context, enc *json.Encoder, topics []string, questID string, last map[string][]byte, change Change) error {
	if s.Snapshotter != nil {
		s.Snapshotter.Invalidate(change)
	}
	for _, topic := range topics {
		if !change.Affects(topic, questID) {
			continue
		}
		data, err := s.snapshotForChange(ctx, topic, questID, change)
		if err != nil {
			return writeEnvelope(enc, errorEnvelope(nil, err))
		}
		raw, err := json.Marshal(data)
		if err != nil {
			return writeEnvelope(enc, errorEnvelope(nil, err))
		}
		if string(raw) == string(last[topic]) {
			continue
		}
		last[topic] = raw
		if err := writeEnvelope(enc, Envelope{Type: "event", Topic: topic, Data: data}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) snapshot(ctx context.Context, topic, questID string) (any, error) {
	return s.snapshotForChange(ctx, topic, questID, Change{})
}

func (s *Server) snapshotForChange(ctx context.Context, topic, questID string, change Change) (any, error) {
	switch topic {
	case topicBoard:
		return s.Snapshotter.BoardForChange(change)
	case topicTracker:
		return s.Snapshotter.TrackerForChange(change)
	case topicQuest:
		if questID == "" {
			return nil, fmt.Errorf("quest_id is required for quest")
		}
		return s.Snapshotter.QuestForChange(questID, change)
	case topicItems:
		return s.Snapshotter.ItemsForChange(change)
	default:
		return nil, fmt.Errorf("unknown method %q", topic)
	}
}

func (s *Server) snapshotSubscribeTopics(req Request) []string {
	if len(req.Topics) == 0 {
		return []string{topicBoard, topicTracker}
	}
	topics := make([]string, 0, len(req.Topics))
	seen := make(map[string]bool, len(req.Topics))
	for _, topic := range req.Topics {
		switch topic {
		case topicBoard, topicTracker, topicQuest, topicItems:
			if !seen[topic] {
				topics = append(topics, topic)
				seen[topic] = true
			}
		}
	}
	if len(topics) == 0 && !subscribesActiveItem(req) {
		return []string{topicBoard, topicTracker}
	}
	return topics
}

func (s *Server) subscribedTopics(req Request) []string {
	topics := s.snapshotSubscribeTopics(req)
	if subscribesActiveItem(req) {
		topics = append(topics, topicActiveItem)
	}
	return topics
}

func writeEnvelope(enc *json.Encoder, env Envelope) error {
	return enc.Encode(env)
}

func errorEnvelope(id json.RawMessage, err error) Envelope {
	return Envelope{Type: "response", ID: id, OK: boolPtr(false), Error: err.Error()}
}

func boolPtr(v bool) *bool { return &v }
