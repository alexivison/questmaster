//go:build linux || darwin

// Package message provides relay, broadcast, read, report-back, and worker enumeration.
package message

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// LargeMessageThreshold is the character count above which messages use file indirection.
// Matches party-relay.sh relay_needs_file threshold.
const LargeMessageThreshold = 200

// MasterPrefix is prepended to messages sent from a master to workers.
const MasterPrefix = "[MASTER] "

const primaryRole = "primary"

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

// Relay sends a message to a worker's primary pane.
func (s *Service) Relay(ctx context.Context, workerID, message string) error {
	if err := s.client.EnsureSessionRunning(ctx, workerID, "worker"); err != nil {
		return err
	}

	target, err := s.client.ResolveRole(ctx, workerID, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve primary pane in %q: %w", workerID, err)
	}

	msg, _, err := prepareMessage(MasterPrefix + message)
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

	msg, _, err := prepareMessage(MasterPrefix + message)
	if err != nil {
		return BroadcastResult{}, err
	}

	result := BroadcastResult{Registered: len(workers)}
	var transportErr error
	for _, wid := range workers {
		alive, err := s.client.HasSession(ctx, wid)
		if err != nil {
			transportErr = fmt.Errorf("check worker %s: %w", wid, err)
			continue // deliver to remaining workers
		}
		if !alive {
			continue
		}
		target, err := s.client.ResolveRole(ctx, wid, primaryRole, tmux.WindowWorkspace)
		if err != nil {
			continue
		}
		sr := s.client.Send(ctx, target, msg)
		if sr.Err == nil {
			result.Delivered++
		}
	}
	return result, transportErr
}

// Read captures output from a worker's primary pane.
func (s *Service) Read(ctx context.Context, workerID string, lines int) (string, error) {
	if err := s.client.EnsureSessionRunning(ctx, workerID, "worker"); err != nil {
		return "", err
	}

	m, err := s.store.Read(workerID)
	if err != nil {
		return "", fmt.Errorf("read manifest: %w", err)
	}

	target, err := s.client.ResolveRole(ctx, workerID, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return "", fmt.Errorf("resolve primary pane in %q: %w", workerID, err)
	}

	raw, err := s.client.Capture(ctx, target, lines)
	if err != nil {
		return "", err
	}
	filtered := filterPrimaryPaneLines(m, raw, lines)
	return strings.Join(filtered, "\n"), nil
}

// Report sends a report-back message from a worker to its master's primary pane.
// Formats as [WORKER:<sessionID>] <message> per the worker report-back contract.
func (s *Service) Report(ctx context.Context, sessionID, message string) error {
	m, err := s.store.Read(sessionID)
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}

	parent := m.ExtraString("parent_session")
	if parent == "" {
		return fmt.Errorf("session %q has no parent_session — not a worker", sessionID)
	}

	if err := s.client.EnsureSessionRunning(ctx, parent, "master"); err != nil {
		return err
	}

	target, err := s.client.ResolveRole(ctx, parent, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve primary pane in master %q: %w", parent, err)
	}

	prefix := fmt.Sprintf("[WORKER:%s] ", sessionID)
	msg, indirected, err := prepareMessage(prefix + message)
	if err != nil {
		return err
	}
	// For file-indirected messages, the prefix is inside the file but also
	// needs to be visible in the pane so the master can identify the sender.
	if indirected {
		msg = prefix + msg
	}
	result := s.client.Send(ctx, target, msg)
	return result.Err
}

// Workers returns status information for all workers of a master session.
func (s *Service) Workers(ctx context.Context, masterID string) ([]WorkerInfo, error) {
	workerIDs, err := s.store.GetWorkers(masterID)
	if err != nil {
		return nil, fmt.Errorf("get workers: %w", err)
	}

	seen := make(map[string]bool, len(workerIDs))
	workers := make([]WorkerInfo, 0, len(workerIDs))
	for _, wid := range workerIDs {
		if seen[wid] {
			continue
		}
		seen[wid] = true
		info := WorkerInfo{SessionID: wid}

		alive, err := s.client.HasSession(ctx, wid)
		switch {
		case err != nil:
			info.Status = "error"
		case alive:
			info.Status = "active"
		default:
			info.Status = "stopped"
		}

		m, readErr := s.store.Read(wid)
		if readErr == nil {
			info.Title = m.Title
		}

		// Auto-prune ghost entries: no tmux session and no manifest.
		if info.Status == "stopped" && readErr != nil {
			_ = s.store.RemoveWorker(masterID, wid)
			continue
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
	return "Read and follow the instructions in " + path + ". Act on them now, then report back with results."
}

// prepareMessage applies file indirection if needed, returning the message to send
// and whether indirection was applied.
//
// Large messages are written to /tmp/party-relay-*.md temp files. These files are
// the only copy of the message body and cannot be safely reaped on a timer (the
// receiver may not process input for extended periods during long tool runs).
// Files accumulate in /tmp and are cleaned by the OS on reboot.
func prepareMessage(msg string) (string, bool, error) {
	if !needsFileIndirection(msg) {
		return msg, false, nil
	}
	path, err := writeRelayFile(msg)
	if err != nil {
		return "", false, err
	}
	return relayPointer(path), true, nil
}

func filterPrimaryPaneLines(m state.Manifest, raw string, lines int) []string {
	if primaryAgentName(m) == "codex" {
		return tmux.FilterWizardLines(raw, lines)
	}
	return tmux.FilterAgentLines(raw, lines)
}

func primaryAgentName(m state.Manifest) string {
	for _, spec := range m.Agents {
		if spec.Role == primaryRole && spec.Name != "" {
			return spec.Name
		}
	}
	if m.ExtraString("claude_session_id") != "" || m.ClaudeBin != "" {
		return "claude"
	}
	if m.ExtraString("codex_thread_id") != "" || m.CodexBin != "" {
		return "codex"
	}
	return ""
}
