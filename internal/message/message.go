//go:build linux || darwin

// Package message provides relay, broadcast, read, report-back, and worker enumeration.
package message

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/charmbracelet/x/ansi"
)

// LargeMessageThreshold is the character count above which messages use file indirection.
const LargeMessageThreshold = 200

const primaryRole = "primary"

// Service provides messaging operations between questmaster sessions.
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
	SessionID string `json:"session_id"`
	Status    string `json:"status"`
	Title     string `json:"title"`
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

	msg, _, err := prepareMessage(message)
	if err != nil {
		return err
	}
	result := s.client.Send(ctx, target, msg)
	return result.Err
}

// RelayFrom sends a message to a worker's primary pane with sender provenance.
func (s *Service) RelayFrom(ctx context.Context, senderID, targetID, message string) error {
	if err := s.client.EnsureSessionRunning(ctx, targetID, "worker"); err != nil {
		return err
	}

	target, err := s.client.ResolveRole(ctx, targetID, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve primary pane in %q: %w", targetID, err)
	}

	msg, _, err := prepareProvenancedMessage(senderID, message)
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

	msg, _, err := prepareMessage(message)
	if err != nil {
		return BroadcastResult{}, err
	}
	return s.broadcastTo(ctx, workers, msg)
}

// BroadcastFrom sends a message with sender provenance to all workers of a master session.
func (s *Service) BroadcastFrom(ctx context.Context, senderID, masterID, message string) (BroadcastResult, error) {
	workers, err := s.store.GetWorkers(masterID)
	if err != nil {
		return BroadcastResult{}, fmt.Errorf("get workers: %w", err)
	}
	if len(workers) == 0 {
		return BroadcastResult{}, nil
	}

	msg, _, err := prepareProvenancedMessage(senderID, message)
	if err != nil {
		return BroadcastResult{}, err
	}
	return s.broadcastTo(ctx, workers, msg)
}

// broadcastTo delivers an already-prepared message to every live worker,
// aggregating per-worker failures. Dead workers (no tmux session) are a
// legitimate state and skipped silently. Live workers whose primary pane cannot
// be resolved, whose send fails, or whose liveness check hits a transport error
// are surfaced via the returned error so a zero- or partial-delivery broadcast is
// never silent — matching the error-returning behavior of Relay.
func (s *Service) broadcastTo(ctx context.Context, workers []string, msg string) (BroadcastResult, error) {
	result := BroadcastResult{Registered: len(workers)}
	var errs []error
	for _, wid := range workers {
		alive, err := s.client.HasSession(ctx, wid)
		if err != nil {
			errs = append(errs, fmt.Errorf("check worker %s: %w", wid, err))
			continue // deliver to remaining workers
		}
		if !alive {
			continue // dead worker — legitimate skip, not a failure
		}
		target, err := s.client.ResolveRole(ctx, wid, primaryRole, tmux.WindowWorkspace)
		if err != nil {
			errs = append(errs, fmt.Errorf("resolve primary pane in %q: %w", wid, err))
			continue
		}
		if sr := s.client.Send(ctx, target, msg); sr.Err != nil {
			errs = append(errs, fmt.Errorf("send to %q: %w", wid, sr.Err))
			continue
		}
		result.Delivered++
	}
	return result, errors.Join(errs...)
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

	primary := primaryAgentName(m)
	if isPiLikeAgent(primary) && lines > 0 {
		if output, ok := readPiActivityOutput(workerID, lines); ok {
			return output, nil
		}
	}

	target, err := s.client.ResolveRole(ctx, workerID, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return "", fmt.Errorf("resolve primary pane in %q: %w", workerID, err)
	}

	raw, err := s.client.Capture(ctx, target, lines)
	if err != nil {
		return "", err
	}
	if isPiLikeAgent(primary) {
		return formatPiRawPaneOutput(raw, lines), nil
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
	msg, indirected, err := prepareMessageWith(prefix+message, reportPointer)
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
	observations := make([]sessionactivity.Observation, 0, len(workerIDs))
	liveness := make(map[string]bool, len(workerIDs))
	for _, wid := range workerIDs {
		if seen[wid] {
			continue
		}
		seen[wid] = true
		info := WorkerInfo{SessionID: wid}

		alive, err := s.client.HasSession(ctx, wid)
		if err != nil {
			info.Status = "error"
		} else {
			liveness[wid] = alive
			observations = append(observations, sessionactivity.Observation{
				Key:       wid,
				SessionID: wid,
				Enabled:   alive,
			})
		}

		m, readErr := s.store.Read(wid)
		if readErr == nil {
			info.Title = m.Title
		}

		// Auto-prune ghost entries: no tmux session and no manifest.
		if err == nil && !alive && readErr != nil {
			_ = s.store.RemoveWorker(masterID, wid)
			continue
		}

		workers = append(workers, info)
	}

	results := sessionactivity.Evaluate(observations)
	for i := range workers {
		if workers[i].Status == "error" {
			continue
		}
		result := results[workers[i].SessionID]
		workers[i].Status = sessionactivity.Label(result.State, liveness[workers[i].SessionID])
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
	f, err := os.CreateTemp("", "qm-relay-*.md")
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

// relayPointer returns the pointer message for a relay file sent
// master→worker. It is imperative because the receiver is expected
// to open the file and act on its contents.
func relayPointer(path string) string {
	return "Read and follow the instructions in " + path + ". Act on them now, then report back with results."
}

func senderPrefix(senderID string) string {
	return "[FROM:" + senderID + "] "
}

// reportPointer returns the pointer message for a relay file sent
// worker→master. It is a readout, not an instruction: the master
// reads the report when convenient and decides next steps.
func reportPointer(path string) string {
	return "Worker report available at " + path + ". Read it to see the results."
}

func prepareProvenancedMessage(senderID, message string) (msg string, indirected bool, err error) {
	prefix := senderPrefix(senderID)
	msg, indirected, err = prepareMessageWith(prefix+message, relayPointer)
	if err != nil {
		return "", false, err
	}
	if indirected {
		msg = prefix + msg
	}
	return msg, indirected, nil
}

// prepareMessage applies file indirection if needed, returning the message to send
// and whether indirection was applied. Uses the imperative relayPointer — suitable
// for master→worker dispatch. Use prepareMessageWith for other directions.
//
// Large messages are written to /tmp/qm-relay-*.md temp files. These files are
// the only copy of the message body and cannot be safely reaped on a timer (the
// receiver may not process input for extended periods during long tool runs).
// Files accumulate in /tmp and are cleaned by the OS on reboot.
func prepareMessage(msg string) (string, bool, error) {
	return prepareMessageWith(msg, relayPointer)
}

// prepareMessageWith behaves like prepareMessage but lets the caller supply the
// pointer phrasing (e.g. reportPointer for worker→master reports).
func prepareMessageWith(msg string, pointer func(string) string) (string, bool, error) {
	if !needsFileIndirection(msg) {
		return msg, false, nil
	}
	path, err := writeRelayFile(msg)
	if err != nil {
		return "", false, err
	}
	return pointer(path), true, nil
}

func readPiActivityOutput(sessionID string, lines int) (string, bool) {
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil || ss.Version != state.SchemaVersion {
		return "", false
	}
	pane, ok := ss.Panes[primaryRole]
	if !ok || (pane.Agent != "" && !isPiLikeAgent(pane.Agent)) {
		return "", false
	}
	if len(pane.Recent) > 0 {
		return strings.Join(tailLines(pane.Recent, lines), "\n"), true
	}

	snippet := strings.TrimSpace(pane.Activity)
	if snippet == "" {
		return "", false
	}
	return strings.Join(tailLines(strings.Split(snippet, "\n"), lines), "\n"), true
}

func formatPiRawPaneOutput(raw string, lines int) string {
	cleaned := cleanRawPaneLines(raw, lines)
	if len(cleaned) == 0 {
		return "[raw Pi pane output — no usable activity sidecar]\n(no captured output)"
	}
	return "[raw Pi pane output — no usable activity sidecar]\n" + strings.Join(cleaned, "\n")
}

func cleanRawPaneLines(raw string, max int) []string {
	cleaned := make([]string, 0)
	for _, line := range strings.Split(raw, "\n") {
		clean := strings.TrimSpace(ansi.Strip(line))
		if clean == "" {
			continue
		}
		cleaned = append(cleaned, clean)
	}
	return tailLines(cleaned, max)
}

func tailLines(lines []string, max int) []string {
	if max > 0 && len(lines) > max {
		return lines[len(lines)-max:]
	}
	return lines
}

func filterPrimaryPaneLines(m state.Manifest, raw string, lines int) []string {
	if primaryAgentName(m) == "codex" {
		return tmux.FilterCodexLines(raw, lines)
	}
	return tmux.FilterAgentLines(raw, lines)
}

// isPiLikeAgent reports whether the agent uses the Pi activity-sidecar
// contract for state tracking and structured read output. oh-my-pi (omp) is
// a Pi fork that emits the same event stream, so both share the rich read
// path and fall back to the same raw-pane formatting.
func isPiLikeAgent(name string) bool {
	return name == "pi" || name == "omp"
}

func primaryAgentName(m state.Manifest) string {
	for _, spec := range m.Agents {
		if spec.Role == primaryRole && spec.Name != "" {
			return spec.Name
		}
	}
	return ""
}
