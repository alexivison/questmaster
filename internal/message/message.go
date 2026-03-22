//go:build linux || darwin

// Package message provides relay, broadcast, read, report-back, and worker enumeration.
package message

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// LargeMessageThreshold is the character count above which messages use file indirection.
// Matches party-relay.sh relay_needs_file threshold.
const LargeMessageThreshold = 200

// Service provides messaging operations between party sessions.
type Service struct {
	store  *state.Store
	client *tmux.Client
}

// NewService creates a messaging service.
func NewService(store *state.Store, client *tmux.Client) *Service {
	return &Service{store: store, client: client}
}

// WorkerInfo holds status information for a worker session.
type WorkerInfo struct {
	SessionID string
	Status    string // "active" or "stopped"
	Title     string
}

// Relay sends a message to a worker's Claude pane.
func (s *Service) Relay(ctx context.Context, workerID, message string) error {
	alive, err := s.client.HasSession(ctx, workerID)
	if err != nil {
		return fmt.Errorf("check session: %w", err)
	}
	if !alive {
		return fmt.Errorf("worker session %q is not running", workerID)
	}

	target, err := s.client.ResolveRole(ctx, workerID, "claude", tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve claude pane in %q: %w", workerID, err)
	}

	msg, err := prepareMessage(message)
	if err != nil {
		return err
	}
	result := s.client.Send(ctx, target, msg)
	return result.Err
}

// BroadcastResult distinguishes "no registered workers" from "registered but none reachable."
type BroadcastResult struct {
	Registered int // total workers in manifest
	Delivered  int // workers that received the message
}

// Broadcast sends a message to all workers of a master session.
func (s *Service) Broadcast(ctx context.Context, masterID, message string) (BroadcastResult, error) {
	workers, err := s.store.GetWorkers(masterID)
	if err != nil {
		return BroadcastResult{}, fmt.Errorf("get workers: %w", err)
	}
	if len(workers) == 0 {
		return BroadcastResult{}, nil
	}

	msg, err := prepareMessage(message)
	if err != nil {
		return BroadcastResult{}, err
	}

	result := BroadcastResult{Registered: len(workers)}
	for _, wid := range workers {
		alive, err := s.client.HasSession(ctx, wid)
		if err != nil || !alive {
			continue
		}
		target, err := s.client.ResolveRole(ctx, wid, "claude", tmux.WindowWorkspace)
		if err != nil {
			continue
		}
		sr := s.client.Send(ctx, target, msg)
		if sr.Err == nil {
			result.Delivered++
		}
	}
	return result, nil
}

// Read captures output from a worker's Claude pane.
func (s *Service) Read(ctx context.Context, workerID string, lines int) (string, error) {
	alive, err := s.client.HasSession(ctx, workerID)
	if err != nil {
		return "", fmt.Errorf("check session: %w", err)
	}
	if !alive {
		return "", fmt.Errorf("worker session %q is not running", workerID)
	}

	target, err := s.client.ResolveRole(ctx, workerID, "claude", tmux.WindowWorkspace)
	if err != nil {
		return "", fmt.Errorf("resolve claude pane in %q: %w", workerID, err)
	}

	return s.client.Capture(ctx, target, lines)
}

// Report sends a report-back message from a worker to its master's Claude pane.
// Formats as [WORKER:<sessionID>] <message> per the worker report-back contract.
func (s *Service) Report(ctx context.Context, sessionID, message string) error {
	m, err := s.store.Read(sessionID)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}

	parent := getExtraField(&m, "parent_session")
	if parent == "" {
		return fmt.Errorf("session %q has no parent_session — not a worker", sessionID)
	}

	alive, err := s.client.HasSession(ctx, parent)
	if err != nil {
		return fmt.Errorf("check master session: %w", err)
	}
	if !alive {
		return fmt.Errorf("master session %q is not running", parent)
	}

	target, err := s.client.ResolveRole(ctx, parent, "claude", tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve claude pane in master %q: %w", parent, err)
	}

	prefix := fmt.Sprintf("[WORKER:%s] ", sessionID)
	msg, err := prepareMessage(message)
	if err != nil {
		return err
	}
	result := s.client.Send(ctx, target, prefix+msg)
	return result.Err
}

// Workers returns status information for all workers of a master session.
func (s *Service) Workers(ctx context.Context, masterID string) ([]WorkerInfo, error) {
	workerIDs, err := s.store.GetWorkers(masterID)
	if err != nil {
		return nil, fmt.Errorf("get workers: %w", err)
	}

	workers := make([]WorkerInfo, 0, len(workerIDs))
	for _, wid := range workerIDs {
		info := WorkerInfo{SessionID: wid}

		alive, err := s.client.HasSession(ctx, wid)
		if err == nil && alive {
			info.Status = "active"
		} else {
			info.Status = "stopped"
		}

		if m, err := s.store.Read(wid); err == nil {
			info.Title = m.Title
		}

		workers = append(workers, info)
	}
	return workers, nil
}

// needsFileIndirection returns true if the message exceeds the tmux send-keys
// reliability threshold or contains newlines.
func needsFileIndirection(msg string) bool {
	return len(msg) > LargeMessageThreshold || strings.Contains(msg, "\n")
}

// writeRelayFile writes message content to a temp file for large-message indirection.
// Returns the temp file path.
func writeRelayFile(content string) (string, error) {
	f, err := os.CreateTemp("", "party-relay-*.md")
	if err != nil {
		return "", fmt.Errorf("create relay file: %w", err)
	}
	defer f.Close()

	if _, err := fmt.Fprintf(f, "%s\n", content); err != nil {
		os.Remove(f.Name())
		return "", fmt.Errorf("write relay file: %w", err)
	}
	return f.Name(), nil
}

// relayPointer returns the pointer message for a relay file.
func relayPointer(path string) string {
	return "Read relay instructions at " + path
}

// prepareMessage applies file indirection if needed, returning the message to send.
func prepareMessage(msg string) (string, error) {
	if !needsFileIndirection(msg) {
		return msg, nil
	}
	path, err := writeRelayFile(msg)
	if err != nil {
		return "", err
	}
	return relayPointer(path), nil
}

// getExtraField reads a string from the manifest's Extra map.
func getExtraField(m *state.Manifest, key string) string {
	raw, ok := m.Extra[key]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}
