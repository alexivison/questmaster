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
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	topicBoard   = "board"
	topicTracker = "tracker"
	topicQuest   = "quest"
)

// Request is one JSON line sent by a client.
type Request struct {
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Topics  []string        `json:"topics,omitempty"`
	QuestID string          `json:"quest_id,omitempty"`
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
	SocketPath  string
	Snapshotter *Snapshotter
	Interval    time.Duration
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
		s.Snapshotter = NewSnapshotter(nil, nil, nil)
	}
	if s.Interval <= 0 {
		s.Interval = time.Second
	}
	if err := prepareSocket(path); err != nil {
		return err
	}

	ln, err := net.Listen("unix", path)
	if err != nil {
		return fmt.Errorf("listen %s: %w", path, err)
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
		go s.handleConn(ctx, conn)
	}
}

func prepareSocket(path string) error {
	if path == "" {
		return fmt.Errorf("socket path is required")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}
	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("stat socket: %w", err)
	}
	conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
	if err == nil {
		conn.Close() //nolint:errcheck
		return fmt.Errorf("serve socket already active at %s", path)
	}
	if err := os.Remove(path); err != nil {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}

func (s *Server) handleConn(ctx context.Context, conn net.Conn) {
	defer conn.Close() //nolint:errcheck

	dec := json.NewDecoder(conn)
	enc := json.NewEncoder(conn)
	for {
		var req Request
		if err := dec.Decode(&req); err != nil {
			return
		}
		if req.Method == "subscribe" {
			if err := s.writeResponse(ctx, enc, req.ID, "subscribe", map[string]any{"subscribed": s.subscribeTopics(req)}); err != nil {
				return
			}
			_ = s.subscribe(ctx, enc, req)
			return
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

func (s *Server) subscribe(ctx context.Context, enc *json.Encoder, req Request) error {
	topics := s.subscribeTopics(req)
	last := make(map[string][]byte, len(topics))
	if err := s.pushChanged(ctx, enc, topics, req.QuestID, last); err != nil {
		return err
	}

	ticker := time.NewTicker(s.Interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := s.pushChanged(ctx, enc, topics, req.QuestID, last); err != nil {
				return err
			}
		}
	}
}

func (s *Server) pushChanged(ctx context.Context, enc *json.Encoder, topics []string, questID string, last map[string][]byte) error {
	for _, topic := range topics {
		data, err := s.snapshot(ctx, topic, questID)
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
	switch topic {
	case topicBoard:
		return s.Snapshotter.Board(ctx)
	case topicTracker:
		return s.Snapshotter.Tracker(ctx)
	case topicQuest:
		if questID == "" {
			return nil, fmt.Errorf("quest_id is required for quest")
		}
		return s.Snapshotter.Quest(ctx, questID)
	default:
		return nil, fmt.Errorf("unknown method %q", topic)
	}
}

func (s *Server) subscribeTopics(req Request) []string {
	if len(req.Topics) == 0 {
		return []string{topicBoard, topicTracker}
	}
	topics := make([]string, 0, len(req.Topics))
	seen := make(map[string]bool, len(req.Topics))
	for _, topic := range req.Topics {
		switch topic {
		case topicBoard, topicTracker, topicQuest:
			if !seen[topic] {
				topics = append(topics, topic)
				seen[topic] = true
			}
		}
	}
	if len(topics) == 0 {
		return []string{topicBoard, topicTracker}
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
