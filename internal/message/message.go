//go:build linux || darwin

// Package message provides relay, broadcast, read, report-back, and worker enumeration.
package message

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
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
	dial   func(context.Context, string, string) (net.Conn, error)
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
	m, err := s.validateRelayTarget(workerID)
	if err != nil {
		return err
	}
	if err := s.client.EnsureSessionRunning(ctx, workerID, "worker"); err != nil {
		return err
	}
	return s.deliver(ctx, workerID, m, newTmuxPayload(message, relayPointer, ""))
}

// RelayFrom sends a message to a worker's primary pane with sender provenance.
func (s *Service) RelayFrom(ctx context.Context, senderID, targetID, message string) error {
	if !state.IsValidSessionID(senderID) {
		return fmt.Errorf("invalid sender id: %q", senderID)
	}
	m, err := s.validateRelayTarget(targetID)
	if err != nil {
		return err
	}
	if err := s.client.EnsureSessionRunning(ctx, targetID, "worker"); err != nil {
		return err
	}
	prefix := senderPrefix(senderID)
	return s.deliver(ctx, targetID, m, newTmuxPayload(prefix+message, relayPointer, prefix))
}

func (s *Service) validateRelayTarget(workerID string) (state.Manifest, error) {
	if !state.IsValidSessionID(workerID) {
		return state.Manifest{}, fmt.Errorf("invalid worker id: %q", workerID)
	}
	if s == nil || s.store == nil {
		return state.Manifest{}, nil
	}
	m, err := s.store.Read(workerID)
	if err != nil {
		return state.Manifest{}, fmt.Errorf("read worker manifest: %w", err)
	}
	if err := rejectPlainSession(m, workerID); err != nil {
		return state.Manifest{}, err
	}
	return m, nil
}

func (s *Service) ensureOpenCodeRelayReady(ctx context.Context, sessionID string, m state.Manifest, target string) error {
	if s == nil || s.store == nil {
		return nil
	}
	if err := rejectPlainSession(m, sessionID); err != nil {
		return err
	}
	if primaryAgentName(m) != "opencode" {
		return nil
	}
	ss, err := state.LoadSessionStateAt(s.store.Root(), sessionID)
	if err != nil {
		return fmt.Errorf("read OpenCode hook state: %w", err)
	}
	result := sessionactivity.FromState(ss)
	if result.State != "idle" && result.State != "done" {
		return fmt.Errorf("opencode relay unsafe for %q: bridge state %s (requires idle or done)", sessionID, result.State)
	}
	identity, ok := m.OpenCodeNativeIdentity()
	if !ok || identity.PID <= 0 {
		return nil
	}
	pid, _, err := s.client.PaneIdentity(ctx, target)
	if err != nil {
		return fmt.Errorf("resolve OpenCode pane identity for relay: %w", err)
	}
	if pid != identity.PID {
		return fmt.Errorf("opencode relay unsafe for %q: pane pid %d does not match hook pid %d", sessionID, pid, identity.PID)
	}
	return nil
}

type tmuxPayload struct {
	logical       string
	pointer       func(string) string
	pointerPrefix string
	prepared      bool
	message       string
	err           error
}

func newTmuxPayload(logical string, pointer func(string) string, pointerPrefix string) *tmuxPayload {
	return &tmuxPayload{logical: logical, pointer: pointer, pointerPrefix: pointerPrefix}
}

func (p *tmuxPayload) tmuxMessage() (string, error) {
	if p.prepared {
		return p.message, p.err
	}
	p.prepared = true
	message, indirected, err := prepareMessageWith(p.logical, p.pointer)
	if err != nil {
		p.err = err
		return "", err
	}
	p.message = message
	if indirected {
		p.message = p.pointerPrefix + p.message
	}
	return p.message, nil
}

// deliver uses the provider-native transport when it can establish availability
// before sending. Tmux is only a pre-send unavailability fallback.
func (s *Service) deliver(ctx context.Context, sessionID string, m state.Manifest, payload *tmuxPayload) error {
	target, err := s.client.ResolveRole(ctx, sessionID, primaryRole, tmux.WindowWorkspace)
	if err != nil {
		return fmt.Errorf("resolve primary pane in %q: %w", sessionID, err)
	}
	if err := s.nativeDeliver(ctx, sessionID, m, target, payload.logical); err == nil {
		return nil
	} else if !errors.Is(err, errNativeUnavailable) {
		return err
	}
	if primaryAgentName(m) == "opencode" {
		if err := s.ensureOpenCodeRelayReady(ctx, sessionID, m, target); err != nil {
			return err
		}
	}
	message, err := payload.tmuxMessage()
	if err != nil {
		return err
	}
	return s.client.Send(ctx, target, message).Err
}

// BroadcastResult distinguishes "no registered workers" from "registered but none reachable."
type BroadcastResult struct {
	Registered int // total workers in manifest
	Delivered  int // workers whose local transport write completed
}

// Broadcast sends a message to all workers of a master session.
func (s *Service) Broadcast(ctx context.Context, masterID, message string) (BroadcastResult, error) {
	m, err := s.store.Read(masterID)
	if err != nil {
		return BroadcastResult{}, fmt.Errorf("get workers: %w", err)
	}
	if err := rejectPlainSession(m, masterID); err != nil {
		return BroadcastResult{}, err
	}
	workers := m.Workers
	if len(workers) == 0 {
		return BroadcastResult{}, nil
	}

	return s.broadcastTo(ctx, workers, newTmuxPayload(message, relayPointer, ""))
}

// BroadcastFrom sends a message with sender provenance to all workers of a master session.
func (s *Service) BroadcastFrom(ctx context.Context, senderID, masterID, message string) (BroadcastResult, error) {
	if !state.IsValidSessionID(senderID) {
		return BroadcastResult{}, fmt.Errorf("invalid sender id: %q", senderID)
	}
	m, err := s.store.Read(masterID)
	if err != nil {
		return BroadcastResult{}, fmt.Errorf("get workers: %w", err)
	}
	if err := rejectPlainSession(m, masterID); err != nil {
		return BroadcastResult{}, err
	}
	workers := m.Workers
	if len(workers) == 0 {
		return BroadcastResult{}, nil
	}

	prefix := senderPrefix(senderID)
	return s.broadcastTo(ctx, workers, newTmuxPayload(prefix+message, relayPointer, prefix))
}

// broadcastTo delivers one logical payload to every live worker,
// aggregating per-worker failures. Dead workers (no tmux session) are a
// legitimate state and skipped silently. Live workers whose primary pane cannot
// be resolved, whose send fails, or whose liveness check hits a transport error
// are surfaced via the returned error so a zero- or partial-delivery broadcast is
// never silent — matching the error-returning behavior of Relay.
func (s *Service) broadcastTo(ctx context.Context, workers []string, payload *tmuxPayload) (BroadcastResult, error) {
	result := BroadcastResult{Registered: len(workers)}
	var errs []error
	for _, wid := range workers {
		if !state.IsValidSessionID(wid) {
			errs = append(errs, fmt.Errorf("invalid worker id: %q", wid))
			continue
		}
		alive, err := s.client.HasSession(ctx, wid)
		if err != nil {
			errs = append(errs, fmt.Errorf("check worker %s: %w", wid, err))
			continue // deliver to remaining workers
		}
		if !alive {
			continue // dead worker — legitimate skip, not a failure
		}
		m, err := s.validateRelayTarget(wid)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if err := s.deliver(ctx, wid, m, payload); err != nil {
			errs = append(errs, fmt.Errorf("send to %q: %w", wid, err))
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
	if len(m.Agents) == 0 {
		target := tmux.PaneTarget(workerID, tmux.WindowWorkspace, 0)
		raw, err := s.client.Capture(ctx, target, lines)
		if err != nil {
			return "", err
		}
		return strings.Join(cleanRawPaneLines(raw, lines), "\n"), nil
	}

	primary := primaryAgentName(m)
	if isHookActivityAgent(primary) && lines > 0 {
		if output, ok := readHookActivityOutput(workerID, lines, primary); ok {
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
	parentManifest, err := s.store.Read(parent)
	if err != nil {
		return fmt.Errorf("read parent manifest: %w", err)
	}
	if err := rejectPlainSession(parentManifest, parent); err != nil {
		return err
	}

	if err := s.client.EnsureSessionRunning(ctx, parent, "master"); err != nil {
		return err
	}

	prefix := fmt.Sprintf("[WORKER:%s] ", sessionID)
	return s.deliver(ctx, parent, parentManifest, newTmuxPayload(prefix+message, reportPointer, prefix))
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

// prepareMessageWith turns a logical payload into tmux-safe input only when the
// fallback transport needs it. Native delivery always receives the original text.
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

func rejectPlainSession(m state.Manifest, sessionID string) error {
	if len(m.Agents) == 0 {
		return fmt.Errorf("session %s has no agent (plain terminal session)", sessionID)
	}
	return nil
}

func readHookActivityOutput(sessionID string, lines int, agent string) (string, bool) {
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil || ss.Version != state.SchemaVersion {
		return "", false
	}
	pane, ok := ss.Panes[primaryRole]
	if !ok || (pane.Agent != "" && !sameHookActivityAgent(pane.Agent, agent)) {
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
	if agent.UsesCodexFilter(primaryAgentName(m)) {
		return tmux.FilterCodexLines(raw, lines)
	}
	return tmux.FilterAgentLines(raw, lines)
}

// isPiLikeAgent reports whether the agent uses the Pi activity-sidecar
// contract for state tracking and structured read output. The set is declared
// by the agent package (StateSidecar), not duplicated here.
func isPiLikeAgent(name string) bool {
	return agent.UsesSidecarState(name)
}

func isHookActivityAgent(name string) bool {
	return agent.UsesHookActivityState(name)
}

func sameHookActivityAgent(paneAgent, manifestAgent string) bool {
	if paneAgent == manifestAgent {
		return true
	}
	return isPiLikeAgent(paneAgent) && isPiLikeAgent(manifestAgent)
}

func primaryAgentName(m state.Manifest) string {
	for _, spec := range m.Agents {
		if spec.Role == primaryRole && spec.Name != "" {
			return spec.Name
		}
	}
	return ""
}
