//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/alexivison/questmaster/internal/dirsuggest"
	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/tmux"
)

const (
	// Bump this whenever a payload change cannot be decoded by an older app.
	ServeProtocolVersion = 2

	topicTracker          = "tracker"
	topicDirSuggest       = "dir_suggest"
	topicModels           = "models"
	topicReasoningEfforts = "reasoning_efforts"
	topicWorkerFeed       = "worker_feed"
	topicPullRequests     = "pull_requests"
)

// Request is one JSON line sent by a client.
type Request struct {
	ID              json.RawMessage `json:"id,omitempty"`
	Method          string          `json:"method"`
	Topics          []string        `json:"topics,omitempty"`
	Data            json.RawMessage `json:"data,omitempty"`
	ProtocolVersion int             `json:"protocol_version,omitempty"`
}

// Envelope is one JSON line sent by serve.
type Envelope struct {
	ProtocolVersion int             `json:"protocol_version"`
	Type            string          `json:"type"`
	ID              json.RawMessage `json:"id,omitempty"`
	OK              *bool           `json:"ok,omitempty"`
	Topic           string          `json:"topic,omitempty"`
	Data            any             `json:"data,omitempty"`
	Error           string          `json:"error,omitempty"`
}

// Server handles daemon snapshots, subscriptions, and mutations.
type Server struct {
	SocketPath    string // Used by the transport test harness.
	Snapshotter   *Snapshotter
	ClockInterval time.Duration

	ChangeSource ChangeSource

	// MutationRunner is injectable for tests; production re-execs this binary
	// for CLI-owned session lifecycle mutations.
	MutationRunner MutationCommandRunner
	TmuxClient     *tmux.Client
	DirQuerier     dirsuggest.DirQuerier
	// ReasoningEfforts overrides harness discovery in tests and embedded use.
	// Nil uses modelsuggest's process-wide cached resolver.
	ReasoningEfforts func(context.Context, string, string) []string
	PRRefresh        func(context.Context, []string, bool) (map[string]prstatus.HostResult, error)
}

// HandleRequest serves daemon runtime requests after the transport gate.
func (s *Server) HandleRequest(ctx context.Context, req Request) Envelope {
	if err := ctx.Err(); err != nil {
		return errorEnvelope(req.ID, err)
	}
	if req.Method == "subscribe" {
		return Envelope{Type: "response", ID: req.ID, OK: boolPtr(true), Topic: req.Method, Data: map[string]any{"subscribed": s.snapshotSubscribeTopics(req)}}
	}
	if isMutationMethod(req.Method) {
		return s.mutationResponse(ctx, req)
	}
	var data any
	var err error
	switch req.Method {
	case topicDirSuggest:
		data, err = s.dirSuggest(req)
	case topicModels:
		data, err = s.models(ctx, req)
	case topicReasoningEfforts:
		data, err = s.reasoningEfforts(ctx, req)
	case topicWorkerFeed:
		data, err = s.workerFeed(req)
	case topicPullRequests:
		data, err = s.pullRequests(req)
	case "pr.refresh":
		data, err = s.refreshPullRequests(ctx, req)
	default:
		data, err = s.snapshot(ctx, req.Method)
	}
	if err != nil {
		return errorEnvelope(req.ID, err)
	}
	return Envelope{Type: "response", ID: req.ID, OK: boolPtr(true), Topic: req.Method, Data: data}
}

// Subscribe owns one connection after its subscribe response has been sent.
func (s *Server) Subscribe(ctx context.Context, enc *json.Encoder, req Request, changeSource ChangeSource) error {
	topics := s.snapshotSubscribeTopics(req)
	last := make(map[string][]byte, len(topics))

	// A subscribe request owns the connection until the client closes it or the
	// server context is canceled; handleConn returns immediately after this loop.
	changes, unsubscribe := changeSource.Subscribe(ctx)
	defer unsubscribe()

	if err := s.pushChanged(ctx, enc, topics, last, allTopicsChange()); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case change, ok := <-changes:
			if !ok {
				return nil
			}
			if err := s.pushChanged(ctx, enc, topics, last, change); err != nil {
				return err
			}
		}
	}
}

func (s *Server) pushChanged(ctx context.Context, enc *json.Encoder, topics []string, last map[string][]byte, change Change) error {
	if s.Snapshotter != nil {
		s.Snapshotter.Invalidate(change)
	}
	for _, topic := range topics {
		if !change.Affects(topic) {
			continue
		}
		data, err := s.snapshotForChange(ctx, topic, change)
		if err != nil {
			return WriteEnvelope(enc, errorEnvelope(nil, err))
		}
		raw, err := json.Marshal(data)
		if err != nil {
			return WriteEnvelope(enc, errorEnvelope(nil, err))
		}
		if bytes.Equal(raw, last[topic]) {
			continue
		}
		last[topic] = raw
		// Reuse the bytes already marshaled for dedup instead of re-encoding
		// data: json.RawMessage emits them verbatim through enc.Encode.
		env := Envelope{ProtocolVersion: ServeProtocolVersion, Type: "event", Topic: topic, Data: json.RawMessage(raw)}
		if err := WriteEnvelope(enc, env); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) snapshot(ctx context.Context, topic string) (any, error) {
	return s.snapshotForChange(ctx, topic, Change{})
}

func (s *Server) snapshotForChange(ctx context.Context, topic string, change Change) (any, error) {
	switch topic {
	case topicTracker:
		return s.Snapshotter.TrackerForChange(change)
	default:
		return nil, fmt.Errorf("unknown method %q", topic)
	}
}

func (s *Server) snapshotSubscribeTopics(req Request) []string {
	if len(req.Topics) == 0 {
		return []string{topicTracker}
	}
	topics := make([]string, 0, len(req.Topics))
	seen := make(map[string]bool, len(req.Topics))
	for _, topic := range req.Topics {
		switch topic {
		case topicTracker:
			if !seen[topic] {
				topics = append(topics, topic)
				seen[topic] = true
			}
		}
	}
	if len(topics) == 0 {
		return []string{topicTracker}
	}
	return topics
}

func WriteEnvelope(enc *json.Encoder, env Envelope) error {
	if env.ProtocolVersion == 0 {
		env.ProtocolVersion = ServeProtocolVersion
	}
	return enc.Encode(env)
}

func errorEnvelope(id json.RawMessage, err error) Envelope {
	return Envelope{Type: "response", ID: id, OK: boolPtr(false), Error: err.Error()}
}

func boolPtr(v bool) *bool { return &v }
