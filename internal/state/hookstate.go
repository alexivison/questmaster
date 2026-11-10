//go:build linux || darwin

package state

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

// SchemaVersion is the current PaneState/SessionState schema version. Hook
// payloads that load a SessionState with a different Version overwrite it;
// readers (the tracker) treat foreign-version state as `unknown`.
const SchemaVersion = 1

// StateJSONLMaxSize is the rotation threshold for state.jsonl. When the
// file exceeds this size, the writer rotates it to state.jsonl.1 and
// starts a fresh log. One historical file is kept.
const StateJSONLMaxSize = 1 << 20 // 1 MiB

var processDefaultStateRoot = defaultStateRoot(os.Getenv("HOME"))

// DoneToIdleGrace is how long a completed agent turn stays visibly "done"
// before an observing tracker can fold it back to idle.
const DoneToIdleGrace = 10 * time.Second

// StartingToIdleGrace allows a resumed agent to reach its prompt before a
// SessionStart with no following turn is treated as idle.
const StartingToIdleGrace = 15 * time.Second

const (
	ArtifactKindHTML     = "html"
	ArtifactKindMarkdown = "markdown"
	ArtifactKindImage    = "image"

	ArtifactScopeSession = "session"
	ArtifactScopeProject = "project"
	ArtifactScopeAll     = "all"
)

var ensuredSessionStateDirs sync.Map

// Artifact is one file reference that may be linked to several sessions.
type Artifact struct {
	ID                 string   `json:"id,omitempty"`
	Kind               string   `json:"kind"`
	Path               string   `json:"path"`
	Label              string   `json:"label,omitempty"`
	SessionID          string   `json:"session_id,omitempty"` // Legacy projection for older readers.
	SessionIDs         []string `json:"session_ids,omitempty"`
	CreatedBySessionID string   `json:"created_by_session_id,omitempty"`
	ProjectID          string   `json:"project_id"`
	AddedAt            string   `json:"added_at"`
}

// SessionState is the authoritative per-session state snapshot written by
// hooks and read by the tracker. One file per session at
// <state_root>/<session_id>/state.json.
type SessionState struct {
	SessionID string               `json:"session_id"`
	Version   int                  `json:"version"`
	Panes     map[string]PaneState `json:"panes"`
	SeenAt    time.Time            `json:"seen_at"`

	// Artifacts are runtime-only viewer references for this session. The bytes
	// remain at Path.
	Artifacts []Artifact `json:"artifacts,omitempty"`
}

type ClaudeOpenChatAction struct {
	ToolUseID string    `json:"tool_use_id,omitempty"`
	PromptID  string    `json:"prompt_id,omitempty"`
	StartedAt time.Time `json:"started_at"`
}

// PaneState is the renderer-visible state for one role within a session.
// WorkingSince timestamps the moment State transitioned to "working" and
// is preserved across PreToolUse/PostToolUse cycles within the same turn,
// so the tracker can render an ever-growing "working 2m14s" suffix.
// Agent-specific carry-through fields are populated only by providers that
// emit structured hook metadata.
type PaneState struct {
	Role                    string               `json:"role"`
	Agent                   string               `json:"agent"`
	State                   string               `json:"state"`
	Activity                string               `json:"activity"`
	Tool                    string               `json:"tool,omitempty"`
	RunningTools            []RunningTool        `json:"running_tools,omitempty"`
	Narration               string               `json:"narration,omitempty"`
	NarrationAt             time.Time            `json:"narration_at,omitempty"`
	Seq                     int64                `json:"seq"`
	LastEvent               time.Time            `json:"last_event"`
	LastKind                string               `json:"last_kind"`
	WorkingSince            time.Time            `json:"working_since,omitempty"`
	LastChatAt              time.Time            `json:"last_chat_at,omitempty"`
	ActiveSubagents         map[string]string    `json:"active_subagents,omitempty"`
	ActiveSubagentStartedAt map[string]time.Time `json:"active_subagent_started_at,omitempty"`

	Recent            []string `json:"recent,omitempty"`
	SessionFile       string   `json:"session_file,omitempty"`
	PiSessionID       string   `json:"pi_session_id,omitempty"`
	OpenCodeSessionID string   `json:"opencode_session_id,omitempty"`

	// PendingPartMsgID/PendingPartText buffer an opencode message part whose
	// author role is not yet known. The text is promoted to Activity/Recent only
	// once the matching assistant message.updated arrives, so a user's prompt is
	// never surfaced as the worker's activity.
	PendingPartMsgID    string `json:"pending_part_msg_id,omitempty"`
	PendingPartText     string `json:"pending_part_text,omitempty"`
	PendingFinalMessage string `json:"pending_final_message,omitempty"`
	LastChatStatus      string `json:"last_chat_status,omitempty"`

	ClaudePromptID               string                 `json:"claude_prompt_id,omitempty"`
	ClaudeDisplayMessageID       string                 `json:"claude_display_message_id,omitempty"`
	ClaudeDisplayPromptID        string                 `json:"claude_display_prompt_id,omitempty"`
	ClaudeDisplayFirstBatchAt    *time.Time             `json:"claude_display_first_batch_at,omitempty"`
	ClaudeDisplayEarliestBatchAt time.Time              `json:"claude_display_earliest_batch_at,omitempty"`
	ClaudeDisplayChunks          map[int]string         `json:"claude_display_chunks,omitempty"`
	ClaudeDisplayFinalIndex      int                    `json:"claude_display_final_index,omitempty"`
	ClaudeDisplayFinal           bool                   `json:"claude_display_final,omitempty"`
	ClaudeDisplayAbandoned       bool                   `json:"claude_display_abandoned,omitempty"`
	ClaudeOpenChatActions        []ClaudeOpenChatAction `json:"claude_open_chat_actions,omitempty"`
	ClaudeLastSayMessage         string                 `json:"claude_last_say_message,omitempty"`
	ClaudeLastSayPromptID        string                 `json:"claude_last_say_prompt_id,omitempty"`
	ClaudeLastSayTranscript      string                 `json:"claude_last_say_transcript,omitempty"`
	ClaudeLastStopPromptID       string                 `json:"claude_last_stop_prompt_id,omitempty"`
	ClaudeLastStopTranscript     string                 `json:"claude_last_stop_transcript,omitempty"`
	ClaudeNarrationPath          string                 `json:"claude_narration_path,omitempty"`
	ClaudeNarrationOffset        int64                  `json:"claude_narration_offset,omitempty"`
	ClaudeNarrationSkippingLine  bool                   `json:"claude_narration_skipping_line,omitempty"`
	SubagentWake                 *SubagentWake          `json:"subagent_wake,omitempty"`

	CodexTranscriptPath         string `json:"codex_transcript_path,omitempty"`
	CodexTranscriptOffset       int64  `json:"codex_transcript_offset,omitempty"`
	CodexTranscriptSkippingLine bool   `json:"codex_transcript_skipping_line,omitempty"`
}

// SubagentWake stores the parent pane state to restore after subagents that
// woke an idle parent have all stopped.
type SubagentWake struct {
	State    string   `json:"state,omitempty"`
	Activity string   `json:"activity,omitempty"`
	IDs      []string `json:"ids,omitempty"`
}

// StateRoot resolves the directory that holds per-session state. Honors
// $QUESTMASTER_STATE_ROOT, then falls back to ~/.questmaster-state.
// Returns the empty string when neither an override nor $HOME is set
// (caller treats that as a no-op condition).
// Test binaries must use an isolated root, including when the live root is inherited.
func StateRoot() string {
	if root := os.Getenv(StateRootEnv); root != "" {
		if testing.Testing() && filepath.Clean(root) == processDefaultStateRoot {
			panic("QUESTMASTER_STATE_ROOT must not use the live state root in tests")
		}
		return root
	}
	if testing.Testing() {
		panic("QUESTMASTER_STATE_ROOT must be set in tests")
	}
	return defaultStateRoot(os.Getenv("HOME"))
}

func defaultStateRoot(home string) string {
	if home != "" {
		return filepath.Join(home, ".questmaster-state")
	}
	return ""
}

// OpenCodeConfigDir returns Questmaster's private OpenCode config dir under root.
func OpenCodeConfigDir(root string) string {
	if root == "" {
		return ""
	}
	return filepath.Join(root, "opencode")
}

// SessionStateDir returns <root>/<id>. Caller must ensure id is valid.
func SessionStateDir(root, id string) string {
	return filepath.Join(root, id)
}

// SessionStatePath returns the state.json path for the session.
func SessionStatePath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.json")
}

// SessionStateLogPath returns the state.jsonl path for the session.
func SessionStateLogPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.jsonl")
}

// SessionArtifactsPath returns the command-owned runtime artifact sidecar path
// for the session. Hooks own state.json; artifact commands own this file.
func SessionArtifactsPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "artifacts.json")
}

// SessionHookErrorLogPath returns the hook-errors.log path for the session.
func SessionHookErrorLogPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "hook-errors.log")
}

// SessionStateLockPath returns the flock path. We lock a sibling file
// rather than state.json itself so the atomic rename of state.json never
// races a still-held lock fd.
func SessionStateLockPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.json.lock")
}

// LoadSessionState reads the state.json for a session. Returns (nil, nil)
// if the file does not exist (the renderer should treat this as
// "unknown"). The state root is resolved from $QUESTMASTER_STATE_ROOT
// or $HOME.
func LoadSessionState(id string) (*SessionState, error) {
	return LoadSessionStateAt(StateRoot(), id)
}

// LoadSessionStateAt is LoadSessionState with the state root supplied by the
// caller. A refresh loop that already knows the root (e.g. the tracker's
// fetcher, iterating every session each tick) uses this to skip the per-call
// StateRoot() — two os.Getenv plus a join — on every session.
func LoadSessionStateAt(root, id string) (*SessionState, error) {
	if !IsValidSessionID(id) {
		return nil, fmt.Errorf("invalid session id: %q", id)
	}
	if root == "" {
		return nil, nil
	}
	return loadSessionStateAt(root, id)
}

func loadSessionStateAt(root, id string) (*SessionState, error) {
	path := SessionStatePath(root, id)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	return decodeSessionState(data)
}

func decodeSessionState(data []byte) (*SessionState, error) {
	var s SessionState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("decode session state: %w", err)
	}
	normalizeSessionState(&s)
	return &s, nil
}

func normalizeSessionState(ss *SessionState) {
	if ss.Panes == nil {
		ss.Panes = map[string]PaneState{}
	}
	if legacy, ok := ss.Panes["primary"]; ok {
		canonical, exists := ss.Panes["agent"]
		if !exists || legacy.LastEvent.After(canonical.LastEvent) {
			legacy.Role = "agent"
			ss.Panes["agent"] = legacy
		}
		delete(ss.Panes, "primary")
	}
	for key, pane := range ss.Panes {
		if pane.Role == "primary" {
			pane.Role = "agent"
			ss.Panes[key] = pane
		}
	}
}

// SaveSessionState writes the state.json for a session atomically. The
// write is serialized via flock on a sibling lockfile.
func SaveSessionState(id string, ss *SessionState) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if ss == nil {
		return errors.New("nil session state")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved (set QUESTMASTER_STATE_ROOT or HOME)")
	}
	return withStateLock(root, id, func() error {
		return writeSessionStateLocked(root, id, ss)
	})
}

// UpdateSessionState performs a locked read-modify-write. mutate runs
// against the freshly-loaded state inside the critical section. Returning
// false from mutate aborts the write (used when the freshly-read state no
// longer satisfies the precondition the caller checked optimistically).
//
// This is the only safe way to apply tracker-side mutations like
// done → idle: a naive Load → mutate → Save races against hooks because
// the load happens outside the lock.
func UpdateSessionState(id string, mutate func(*SessionState) bool) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, id, func() error {
		ss, err := loadOrResetSessionStateLocked(root, id)
		if err != nil {
			return err
		}
		if !mutate(ss) {
			return nil
		}
		return writeSessionStateLocked(root, id, ss)
	})
}

// loadOrResetSessionStateLocked loads state.json for a writer that holds the
// state lock, or returns empty state when there is none. state.json is
// ephemeral: hooks rebuild it from the next event. So a file that no longer
// decodes is renamed to state.json.corrupt-<unix> and the writer starts from
// empty state, instead of every later hook failing on it. The rename is noted
// in hook-errors.log.
func loadOrResetSessionStateLocked(root, id string) (*SessionState, error) {
	path := SessionStatePath(root, id)
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &SessionState{SessionID: id, Version: SchemaVersion, Panes: map[string]PaneState{}}, nil
	}
	if err != nil {
		return nil, err
	}
	ss, decodeErr := decodeSessionState(data)
	if decodeErr == nil {
		return ss, nil
	}
	aside := fmt.Sprintf("%s.corrupt-%d", path, time.Now().Unix())
	if err := os.Rename(path, aside); err != nil {
		return nil, errors.Join(decodeErr, fmt.Errorf("move corrupt state aside: %w", err))
	}
	_ = AppendHookErrorAt(root, id, fmt.Sprintf("state.json did not decode (%v); moved it to %s and started from empty state", decodeErr, filepath.Base(aside)))
	return &SessionState{SessionID: id, Version: SchemaVersion, Panes: map[string]PaneState{}}, nil
}

// UpdateAndLog folds the JSONL event append and the state.json
// read-modify-write into a single critical section so the per-event hook
// path takes one flock instead of two. It runs mutate against the freshly-loaded
// SessionState, then appends the possibly enriched event and rewrites state.json
// only when mutate returns true (matching UpdateSessionState).
//
// The event append uses appendRotatingJSONL directly rather than
// AppendStateEvent: the shared per-session lockfile is already held here,
// and re-locking the same file from this process would self-block.
//
// A failed state write does not undo the appended event line.
func UpdateAndLog(id string, ev *StateEvent, mutate func(*SessionState) bool) error {
	return UpdateAndLogAt(StateRoot(), id, ev, mutate)
}

// UpdateAndLogAt is UpdateAndLog with the state root supplied by the caller.
func UpdateAndLogAt(root, id string, ev *StateEvent, mutate func(*SessionState) bool) error {
	return UpdateAndLogWithEventsAt(context.Background(), root, id, ev, mutate, nil)
}

// UpdateAndLogWithEvents appends events produced from the agent event and
// applies their state mutation under one lock. A deadline on ctx bounds the
// wait for the lock; past it nothing is written and the lock error returns.
func UpdateAndLogWithEvents(ctx context.Context, id string, ev *StateEvent, mutate func(*SessionState) bool, extraEvents func(*StateEvent) []*StateEvent) error {
	return UpdateAndLogWithEventsAt(ctx, StateRoot(), id, ev, mutate, extraEvents)
}

// UpdateAndLogWithEventsAt is UpdateAndLogWithEvents with the state root
// supplied by the caller.
func UpdateAndLogWithEventsAt(ctx context.Context, root, id string, ev *StateEvent, mutate func(*SessionState) bool, extraEvents func(*StateEvent) []*StateEvent) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	if ev == nil {
		return errors.New("nil state event")
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	return withStateLockContext(ctx, root, id, func() error {
		ss, err := loadOrResetSessionStateLocked(root, id)
		if err != nil {
			return errors.Join(appendRotatingJSONL(SessionStateLogPath(root, id), *ev), err)
		}
		changed := mutate(ss)
		var extras []*StateEvent
		if extraEvents != nil {
			extras = extraEvents(ev)
		}
		appendErr := appendRotatingJSONL(SessionStateLogPath(root, id), *ev)
		for _, extra := range extras {
			if extra == nil {
				appendErr = errors.Join(appendErr, errors.New("nil state event"))
				continue
			}
			appendErr = errors.Join(appendErr, appendRotatingJSONL(SessionStateLogPath(root, id), *extra))
		}
		if !changed {
			return appendErr
		}
		return errors.Join(appendErr, writeSessionStateLocked(root, id, ss))
	})
}

// UpdateAndLogBatch applies a related group of hook events under one state
// lock. Complete log lines remain visible if writing state.json fails. A
// deadline on ctx bounds the wait for the lock, as in UpdateAndLogWithEvents.
func UpdateAndLogBatch(ctx context.Context, id string, events []*StateEvent, mutate func(*SessionState) bool) error {
	return updateAndLogBatchAt(ctx, StateRoot(), id, events, mutate, func(w io.Writer, data []byte) (int, error) {
		return w.Write(data)
	})
}

func updateAndLogBatchAt(ctx context.Context, root, id string, events []*StateEvent, mutate func(*SessionState) bool, writeEvents func(io.Writer, []byte) (int, error)) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	for _, ev := range events {
		if ev == nil {
			return errors.New("nil state event")
		}
		if ev.Ts.IsZero() {
			ev.Ts = time.Now().UTC()
		}
	}
	return withStateLockContext(ctx, root, id, func() error {
		ss, err := loadOrResetSessionStateLocked(root, id)
		if err != nil {
			return err
		}
		changed := mutate(ss)
		var eventData bytes.Buffer
		encoder := json.NewEncoder(&eventData)
		for _, ev := range events {
			if err := encoder.Encode(ev); err != nil {
				return fmt.Errorf("encode state event: %w", err)
			}
		}
		logPath := SessionStateLogPath(root, id)
		var log *os.File
		var oldSize int64
		if eventData.Len() > 0 {
			log, err = os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
			if err != nil {
				return fmt.Errorf("open state log: %w", err)
			}
			info, statErr := log.Stat()
			if statErr != nil {
				closeErr := log.Close()
				log = nil
				return errors.Join(fmt.Errorf("stat state log: %w", statErr), closeErr)
			}
			oldSize = info.Size()
		}
		if log != nil {
			data := eventData.Bytes()
			written, writeErr := writeEvents(log, data)
			if writeErr == nil && written != len(data) {
				writeErr = io.ErrShortWrite
			}
			closeErr := log.Close()
			log = nil
			if writeErr != nil {
				writtenBytes := written
				if writtenBytes < 0 {
					writtenBytes = 0
				}
				if writtenBytes > len(data) {
					writtenBytes = len(data)
				}
				completeBytes := 0
				if newline := bytes.LastIndexByte(data[:writtenBytes], '\n'); newline >= 0 {
					completeBytes = newline + 1
				}
				truncateErr := os.Truncate(logPath, oldSize+int64(completeBytes))
				if truncateErr != nil {
					truncateErr = fmt.Errorf("truncate incomplete state event: %w", truncateErr)
				}
				return errors.Join(fmt.Errorf("write state events: %w", writeErr), closeErr, truncateErr)
			}
			if closeErr != nil {
				return fmt.Errorf("close state log: %w", closeErr)
			}
		}
		if changed {
			if err := writeSessionStateLocked(root, id, ss); err != nil {
				return err
			}
		}
		if eventData.Len() > 0 {
			if info, err := os.Stat(logPath); err == nil && info.Size() >= StateJSONLMaxSize {
				if err := os.Rename(logPath, logPath+".1"); err != nil {
					return fmt.Errorf("rotate state log: %w", err)
				}
			} else if err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("stat state log for rotation: %w", err)
			}
		}
		return nil
	})
}

type artifactSidecar struct {
	Artifacts []Artifact `json:"artifacts,omitempty"`
}

// ArtifactsRegistryPath returns the durable root-level runtime artifact registry.
func ArtifactsRegistryPath(root string) string {
	return filepath.Join(root, "artifacts.json")
}

// SendLockDir holds the per-pane locks that keep two tmux senders to one pane
// from interleaving (tmux.Client.Send).
func SendLockDir(root string) string {
	return filepath.Join(root, "tmux-send")
}

// SendLockDirForServer isolates pane locks by dedicated server label.
func SendLockDirForServer(root, label string) string {
	return filepath.Join(SendLockDir(root), label)
}

// ArtifactsRegistryLockPath returns the root-level artifact registry lock path.
func ArtifactsRegistryLockPath(root string) string {
	return filepath.Join(root, "artifacts.json.lock")
}

// LoadArtifacts reads runtime artifact references for one session.
func LoadArtifacts(sessionID string) ([]Artifact, error) {
	return LoadArtifactsAt(StateRoot(), sessionID)
}

// LoadArtifactsAt is LoadArtifacts with an explicit state root.
func LoadArtifactsAt(root, sessionID string) ([]Artifact, error) {
	if !IsValidSessionID(sessionID) {
		return nil, fmt.Errorf("invalid session id: %q", sessionID)
	}
	if root == "" {
		return nil, nil
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil {
		return nil, err
	}
	return FilterArtifacts(artifacts, ArtifactScopeSession, sessionID, ""), nil
}

// LoadArtifactsGlobal reads the root-level artifact registry, lazily migrating
// existing per-session sidecars and legacy state.json artifacts when absent.
func LoadArtifactsGlobal(root string) ([]Artifact, error) {
	if root == "" {
		return nil, nil
	}
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var artifacts []Artifact
	err := withFileLock(ArtifactsRegistryLockPath(root), func() error {
		var err error
		artifacts, err = loadArtifactsGlobalLocked(root)
		return err
	})
	return artifacts, err
}

func UpsertArtifact(sessionID string, artifact Artifact) error {
	return UpsertArtifactAt(StateRoot(), sessionID, artifact)
}

// UpsertArtifactAt is UpsertArtifact with an explicit state root.
func UpsertArtifactAt(root, sessionID string, artifact Artifact) error {
	rawLabel, rawKind := artifact.Label, artifact.Kind
	artifact = normalizeArtifact(artifact)
	if artifact.Path == "" {
		return errors.New("artifact path is required")
	}
	if !filepath.IsAbs(artifact.Path) {
		return fmt.Errorf("artifact path must be absolute: %s", artifact.Path)
	}
	if !IsValidSessionID(sessionID) {
		return fmt.Errorf("invalid session id: %q", sessionID)
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withArtifactsRegistryLock(root, func() error {
		artifacts, err := loadArtifactsGlobalLocked(root)
		if err != nil {
			return err
		}
		for i := range artifacts {
			if artifacts[i].Path != artifact.Path {
				continue
			}
			current := artifacts[i]
			alreadyLinked := artifactHasSession(current, sessionID)
			current.SessionIDs = append(current.SessionIDs, sessionID)
			if alreadyLinked {
				if rawLabel != "" {
					current.Label = rawLabel
				}
				if rawKind != "" {
					current.Kind = rawKind
				}
				if artifact.ProjectID != "" {
					current.ProjectID = artifact.ProjectID
				}
				current.AddedAt = artifact.AddedAt
			}
			current = normalizeArtifact(current)
			artifacts[i] = current
			if err := writeArtifactsRegistryLocked(root, artifacts); err != nil {
				return err
			}
			return syncArtifactSidecarsLocked(root, artifacts, current.SessionIDs...)
		}
		artifact.SessionIDs = append(artifact.SessionIDs, sessionID)
		if artifact.CreatedBySessionID == "" {
			artifact.CreatedBySessionID = sessionID
		}
		artifact = normalizeArtifact(artifact)
		artifacts = append(artifacts, artifact)
		if err := writeArtifactsRegistryLocked(root, artifacts); err != nil {
			return err
		}
		return syncArtifactSidecarsLocked(root, artifacts, artifact.SessionIDs...)
	})
}

// UpsertArtifactGlobal upserts an artifact by its path in the root registry.
func UpsertArtifactGlobal(root string, artifact Artifact) error {
	artifact = normalizeArtifact(artifact)
	if artifact.Path == "" {
		return errors.New("artifact path is required")
	}
	if !filepath.IsAbs(artifact.Path) {
		return fmt.Errorf("artifact path must be absolute: %s", artifact.Path)
	}
	if artifact.SessionID != "" && !IsValidSessionID(artifact.SessionID) {
		return fmt.Errorf("invalid session id: %q", artifact.SessionID)
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withArtifactsRegistryLock(root, func() error {
		artifacts, err := loadArtifactsGlobalLocked(root)
		if err != nil {
			return err
		}
		for i := range artifacts {
			if artifacts[i].Path == artifact.Path {
				current := artifacts[i]
				artifact.ID = current.ID
				artifact.SessionIDs = append(artifact.SessionIDs, current.SessionIDs...)
				if artifact.CreatedBySessionID == "" {
					artifact.CreatedBySessionID = current.CreatedBySessionID
				}
				if artifact.ProjectID == "" {
					artifact.ProjectID = current.ProjectID
				}
				artifact = normalizeArtifact(artifact)
				artifacts[i] = artifact
				if err := writeArtifactsRegistryLocked(root, artifacts); err != nil {
					return err
				}
				return syncArtifactSidecarsLocked(root, artifacts, artifact.SessionIDs...)
			}
		}
		return writeArtifactsRegistryLocked(root, append(artifacts, artifact))
	})
}

func RemoveArtifact(sessionID, path string) (bool, error) {
	return RemoveArtifactAt(StateRoot(), sessionID, path)
}

// RemoveArtifactAt is RemoveArtifact with an explicit state root.
func RemoveArtifactAt(root, sessionID, path string) (bool, error) {
	if path == "" {
		return false, errors.New("artifact path is required")
	}
	path = filepath.Clean(path)
	if !IsValidSessionID(sessionID) {
		return false, fmt.Errorf("invalid session id: %q", sessionID)
	}
	if root == "" {
		return false, errors.New("no state root resolved")
	}
	removed := false
	err := withArtifactsRegistryLock(root, func() error {
		artifacts, err := loadArtifactsGlobalLocked(root)
		if err != nil {
			return err
		}
		next := make([]Artifact, 0, len(artifacts))
		affected := []string{sessionID}
		for _, artifact := range artifacts {
			if artifact.Path != path || !artifactHasSession(artifact, sessionID) {
				next = append(next, artifact)
				continue
			}
			removed = true
			affected = append(affected, artifact.SessionIDs...)
			artifact.SessionIDs = removeArtifactSession(artifact.SessionIDs, sessionID)
			artifact.SessionID = ""
			if len(artifact.SessionIDs) != 0 {
				next = append(next, normalizeArtifact(artifact))
			}
		}
		if !removed {
			return nil
		}
		if err := writeArtifactsRegistryLocked(root, next); err != nil {
			return err
		}
		return syncArtifactSidecarsLocked(root, next, affected...)
	})
	return removed, err
}

// RemoveArtifactGlobal removes an artifact by path from the root registry.
func RemoveArtifactGlobal(root, path string) (bool, error) {
	if path == "" {
		return false, errors.New("artifact path is required")
	}
	path = filepath.Clean(path)
	if root == "" {
		return false, errors.New("no state root resolved")
	}
	removed := false
	err := withArtifactsRegistryLock(root, func() error {
		artifacts, err := loadArtifactsGlobalLocked(root)
		if err != nil {
			return err
		}
		next := make([]Artifact, 0, len(artifacts))
		var affected []string
		for _, artifact := range artifacts {
			if artifact.Path == path {
				removed = true
				affected = append(affected, artifact.SessionIDs...)
				continue
			}
			next = append(next, artifact)
		}
		if !removed {
			return nil
		}
		if err := writeArtifactsRegistryLocked(root, next); err != nil {
			return err
		}
		return syncArtifactSidecarsLocked(root, next, affected...)
	})
	return removed, err
}

// DeleteArtifactAt removes the registered file and every session link. The
// registry lock keeps deletion ordered with registration and relinking.
func DeleteArtifactAt(root, idOrPath string) (bool, error) {
	if idOrPath == "" {
		return false, errors.New("artifact id or path is required")
	}
	if root == "" {
		return false, errors.New("no state root resolved")
	}
	removed := false
	err := withArtifactsRegistryLock(root, func() error {
		artifacts, err := loadArtifactsGlobalLocked(root)
		if err != nil {
			return err
		}
		target, found := ArtifactByIDOrPath(artifacts, idOrPath)
		if !found {
			return nil
		}
		info, err := os.Lstat(target.Path)
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect artifact file: %w", err)
		}
		stagedPath := ""
		if err == nil {
			if !info.Mode().IsRegular() && info.Mode()&os.ModeSymlink == 0 {
				return fmt.Errorf("artifact path is not a file: %s", target.Path)
			}
			temp, err := os.CreateTemp(filepath.Dir(target.Path), ".artifact-delete-*")
			if err != nil {
				return fmt.Errorf("stage artifact deletion: %w", err)
			}
			stagedPath = temp.Name()
			if err := temp.Close(); err != nil {
				_ = os.Remove(stagedPath)
				return fmt.Errorf("close deletion staging file: %w", err)
			}
			if err := os.Rename(target.Path, stagedPath); err != nil {
				_ = os.Remove(stagedPath)
				if !errors.Is(err, os.ErrNotExist) {
					return fmt.Errorf("stage artifact file: %w", err)
				}
				stagedPath = ""
			}
		}
		next := make([]Artifact, 0, len(artifacts)-1)
		for _, artifact := range artifacts {
			if artifact.ID != target.ID {
				next = append(next, artifact)
			}
		}
		if err := writeArtifactsRegistryLocked(root, next); err != nil {
			if stagedPath != "" {
				if restoreErr := os.Rename(stagedPath, target.Path); restoreErr != nil {
					return errors.Join(err, fmt.Errorf("restore artifact file from %s: %w", stagedPath, restoreErr))
				}
			}
			return err
		}
		var syncedIDs []string
		// Sidecars are compatibility copies. Restore those already changed if a
		// later write fails, so a reported failure keeps the file registered.
		rollback := func(cause error) error {
			if stagedPath != "" {
				if restoreErr := os.Rename(stagedPath, target.Path); restoreErr != nil {
					return errors.Join(cause, fmt.Errorf("restore artifact file from %s: %w", stagedPath, restoreErr))
				}
			}
			registryErr := writeArtifactsRegistryLocked(root, artifacts)
			sidecarErr := syncArtifactSidecarsLocked(root, artifacts, syncedIDs...)
			return errors.Join(cause, registryErr, sidecarErr)
		}
		for _, sessionID := range target.SessionIDs {
			if err := syncArtifactSidecarsLocked(root, next, sessionID); err != nil {
				return rollback(err)
			}
			syncedIDs = append(syncedIDs, sessionID)
		}
		if stagedPath != "" {
			if err := os.Remove(stagedPath); err != nil {
				return rollback(fmt.Errorf("remove staged artifact file %s: %w", stagedPath, err))
			}
		}
		removed = true
		cleanupManagedArtifactDirectory(root, target)
		return nil
	})
	return removed, err
}

func cleanupManagedArtifactDirectory(root string, artifact Artifact) {
	library := filepath.Join(root, "artifact-files")
	relative, err := filepath.Rel(library, artifact.Path)
	if err != nil || relative == "." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return
	}
	parts := strings.Split(relative, string(filepath.Separator))
	if len(parts) != 3 || parts[1] != artifact.ID || (parts[0] != "ungrouped" && !strings.HasPrefix(parts[0], "project-")) {
		return
	}
	dir := filepath.Join(library, parts[0], parts[1])
	if err := os.Remove(dir); err != nil {
		return // Keep directories containing any other files.
	}
	_ = os.Remove(filepath.Dir(dir))
	_ = os.Remove(library)
}

func FilterArtifacts(artifacts []Artifact, scope, sessionID, projectID string) []Artifact {
	if scope == ArtifactScopeAll {
		return SortedArtifacts(artifacts)
	}
	if scope == ArtifactScopeProject {
		if projectID == "" {
			return nil
		}
		filtered := make([]Artifact, 0, len(artifacts))
		for _, artifact := range artifacts {
			if artifact.ProjectID == projectID {
				filtered = append(filtered, artifact)
			}
		}
		return SortedArtifacts(filtered)
	}

	filtered := make([]Artifact, 0, len(artifacts))
	for _, artifact := range artifacts {
		if artifactHasSession(artifact, sessionID) {
			filtered = append(filtered, artifact)
		}
	}
	return SortedArtifacts(filtered)
}

func loadArtifactsGlobalLocked(root string) ([]Artifact, error) {
	data, err := os.ReadFile(ArtifactsRegistryPath(root))
	if err == nil {
		var payload artifactSidecar
		if err := json.Unmarshal(data, &payload); err != nil {
			return nil, fmt.Errorf("decode artifacts registry: %w", err)
		}
		return SortedArtifacts(dedupeArtifactsByPath(payload.Artifacts)), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	artifacts, err := migrateArtifactsRegistry(root)
	if err != nil {
		return nil, err
	}
	if err := writeArtifactsRegistryLocked(root, artifacts); err != nil {
		return nil, err
	}
	return SortedArtifacts(artifacts), nil
}

func migrateArtifactsRegistry(root string) ([]Artifact, error) {
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	byPath := map[string]Artifact{}
	for _, entry := range entries {
		if !entry.IsDir() || !IsValidSessionID(entry.Name()) {
			continue
		}
		sessionID := entry.Name()
		projectID := artifactProjectID(root, sessionID)
		sidecar, ok, err := loadArtifactsSidecarAt(root, sessionID)
		if err != nil {
			return nil, err
		}
		if ok {
			mergeMigratedArtifacts(byPath, sidecar, sessionID, projectID)
		}
		ss, err := loadSessionStateAt(root, sessionID)
		if err != nil {
			return nil, err
		}
		if ss != nil {
			mergeMigratedArtifacts(byPath, ss.Artifacts, sessionID, projectID)
		}
	}
	out := make([]Artifact, 0, len(byPath))
	for _, artifact := range byPath {
		out = append(out, artifact)
	}
	return SortedArtifacts(out), nil
}

func mergeMigratedArtifacts(byPath map[string]Artifact, artifacts []Artifact, sessionID, projectID string) {
	for _, artifact := range artifacts {
		if artifact.SessionID == "" && len(artifact.SessionIDs) == 0 {
			artifact.SessionID = sessionID
		}
		if artifact.ProjectID == "" {
			artifact.ProjectID = projectID
		}
		artifact = normalizeArtifact(artifact)
		if artifact.Path == "" || !filepath.IsAbs(artifact.Path) {
			continue
		}
		if current, ok := byPath[artifact.Path]; ok {
			artifact = mergeArtifactRecords(current, artifact)
		}
		byPath[artifact.Path] = artifact
	}
}

func artifactProjectID(root, sessionID string) string {
	m, err := OpenStore(root).Read(sessionID)
	if err != nil {
		return ""
	}
	return ProjectIDAt(root, m.Cwd)
}

func loadArtifactsSidecarAt(root, sessionID string) ([]Artifact, bool, error) {
	data, err := os.ReadFile(SessionArtifactsPath(root, sessionID))
	if err == nil {
		var payload artifactSidecar
		if err := json.Unmarshal(data, &payload); err != nil {
			return nil, false, fmt.Errorf("decode artifacts sidecar: %w", err)
		}
		return SortedArtifacts(payload.Artifacts), true, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, false, err
	}
	return nil, false, nil
}

func writeArtifactsLocked(root, sessionID string, artifacts []Artifact) error {
	if err := ensureSessionStateDir(root, sessionID); err != nil {
		return err
	}
	return writeArtifactsSidecarLocked(root, sessionID, artifacts)
}

func writeArtifactsSidecarLocked(root, sessionID string, artifacts []Artifact) error {
	data, err := json.Marshal(artifactSidecar{Artifacts: SortedArtifacts(artifacts)})
	if err != nil {
		return fmt.Errorf("marshal artifacts sidecar: %w", err)
	}
	data = append(data, '\n')
	path := SessionArtifactsPath(root, sessionID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp artifacts: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename artifacts.json: %w", err)
	}
	return nil
}

func withArtifactsRegistryLock(root string, fn func() error) error {
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	return withFileLock(ArtifactsRegistryLockPath(root), fn)
}

func writeArtifactsRegistryLocked(root string, artifacts []Artifact) error {
	data, err := json.Marshal(artifactSidecar{Artifacts: SortedArtifacts(dedupeArtifactsByPath(artifacts))})
	if err != nil {
		return fmt.Errorf("marshal artifacts registry: %w", err)
	}
	data = append(data, '\n')
	path := ArtifactsRegistryPath(root)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp artifacts registry: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename artifacts registry: %w", err)
	}
	return nil
}

func syncArtifactSidecarsLocked(root string, artifacts []Artifact, sessionIDs ...string) error {
	seen := map[string]bool{}
	for _, sessionID := range sessionIDs {
		if sessionID == "" || seen[sessionID] {
			continue
		}
		seen[sessionID] = true
		if !IsValidSessionID(sessionID) {
			continue
		}
		info, err := os.Stat(SessionStateDir(root, sessionID))
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return err
		}
		if !info.IsDir() {
			return fmt.Errorf("session state path is not a directory: %s", SessionStateDir(root, sessionID))
		}
		if err := writeArtifactsSidecarLocked(root, sessionID, FilterArtifacts(artifacts, ArtifactScopeSession, sessionID, "")); err != nil {
			return err
		}
	}
	return nil
}

func dedupeArtifactsByPath(artifacts []Artifact) []Artifact {
	byPath := map[string]Artifact{}
	for _, artifact := range artifacts {
		artifact = normalizeArtifact(artifact)
		if artifact.Path == "" {
			continue
		}
		if current, ok := byPath[artifact.Path]; ok {
			artifact = mergeArtifactRecords(current, artifact)
		}
		byPath[artifact.Path] = artifact
	}
	out := make([]Artifact, 0, len(byPath))
	for _, artifact := range byPath {
		out = append(out, artifact)
	}
	return out
}

func mergeArtifactRecords(current, incoming Artifact) Artifact {
	preferred := current
	if artifactNewer(incoming, current) {
		preferred = incoming
	}
	preferred.SessionIDs = append(append([]string(nil), current.SessionIDs...), incoming.SessionIDs...)
	if preferred.CreatedBySessionID == "" {
		preferred.CreatedBySessionID = current.CreatedBySessionID
	}
	if preferred.ID == "" {
		preferred.ID = current.ID
	}
	return normalizeArtifact(preferred)
}

// ArtifactByIDOrPath resolves a registry record by stable ID or canonical path.
func ArtifactByIDOrPath(artifacts []Artifact, value string) (Artifact, bool) {
	path := value
	if filepath.IsAbs(value) {
		path = filepath.Clean(value)
	}
	for _, artifact := range artifacts {
		if artifact.ID == value || artifact.Path == path {
			return artifact, true
		}
	}
	return Artifact{}, false
}

func artifactHasSession(artifact Artifact, sessionID string) bool {
	for _, id := range artifact.SessionIDs {
		if id == sessionID {
			return true
		}
	}
	return artifact.SessionID == sessionID
}

func removeArtifactSession(ids []string, sessionID string) []string {
	next := make([]string, 0, len(ids))
	for _, id := range ids {
		if id != sessionID {
			next = append(next, id)
		}
	}
	return next
}

func artifactNewer(left, right Artifact) bool {
	leftTime, leftOK := parseArtifactTime(left.AddedAt)
	rightTime, rightOK := parseArtifactTime(right.AddedAt)
	if leftOK && rightOK && !leftTime.Equal(rightTime) {
		return leftTime.After(rightTime)
	}
	if left.AddedAt != right.AddedAt {
		return left.AddedAt > right.AddedAt
	}
	return false
}

func SortedArtifacts(artifacts []Artifact) []Artifact {
	if len(artifacts) == 0 {
		return nil
	}
	out := make([]Artifact, 0, len(artifacts))
	for _, artifact := range artifacts {
		artifact = normalizeArtifact(artifact)
		if artifact.Path == "" {
			continue
		}
		out = append(out, artifact)
	}
	sort.SliceStable(out, func(i, j int) bool {
		left, leftOK := parseArtifactTime(out[i].AddedAt)
		right, rightOK := parseArtifactTime(out[j].AddedAt)
		if leftOK && rightOK && !left.Equal(right) {
			return left.After(right)
		}
		if out[i].AddedAt != out[j].AddedAt {
			return out[i].AddedAt > out[j].AddedAt
		}
		return out[i].Path < out[j].Path
	})
	return out
}

func ArtifactMissing(path string) bool {
	if path == "" {
		return true
	}
	_, err := os.Stat(path)
	return err != nil
}

func ArtifactKindForPath(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".html", ".htm":
		return ArtifactKindHTML
	case ".md", ".markdown":
		return ArtifactKindMarkdown
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg":
		return ArtifactKindImage
	default:
		return ArtifactKindHTML
	}
}

func normalizeArtifact(artifact Artifact) Artifact {
	if artifact.Path != "" {
		artifact.Path = filepath.Clean(artifact.Path)
		if artifact.ID == "" {
			sum := sha256.Sum256([]byte(artifact.Path))
			artifact.ID = fmt.Sprintf("art-%x", sum[:12])
		}
	}
	artifact.Kind = strings.ToLower(strings.TrimSpace(artifact.Kind))
	if artifact.Kind == "" {
		artifact.Kind = ArtifactKindForPath(artifact.Path)
	}
	if artifact.Label == "" && artifact.Path != "" {
		artifact.Label = filepath.Base(artifact.Path)
	}
	if artifact.AddedAt == "" {
		artifact.AddedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	if artifact.CreatedBySessionID == "" && artifact.SessionID != "" {
		artifact.CreatedBySessionID = artifact.SessionID
	}
	ids := append([]string(nil), artifact.SessionIDs...)
	if artifact.SessionID != "" {
		ids = append(ids, artifact.SessionID)
	}
	sort.Strings(ids)
	ids = slices.Compact(ids)
	artifact.SessionIDs = ids
	artifact.SessionID = ""
	if len(ids) > 0 {
		artifact.SessionID = ids[0]
	}
	return artifact
}

func parseArtifactTime(raw string) (time.Time, bool) {
	if raw == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	return t, err == nil
}

// MarkSessionObserved folds completed turns and stale SessionStart states to
// idle in an existing state.json. It never creates state for hookless sessions.
func MarkSessionObserved(id string, now time.Time) (bool, error) {
	return MarkSessionObservedAt(StateRoot(), id, now)
}

// MarkSessionObservedAt applies the same transition for an explicit state root.
// The PR monitor uses its own root even when it runs without an app subscriber.
func MarkSessionObservedAt(root, id string, now time.Time) (bool, error) {
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()

	changed := false
	err := updateExistingSessionStateAt(root, id, func(ss *SessionState) bool {
		pane, ok := ss.Panes["agent"]
		if !ok {
			return false
		}
		grace := DoneToIdleGrace
		if pane.State == "starting" && pane.LastKind == "SessionStart" {
			grace = StartingToIdleGrace
		} else if pane.State != "done" {
			return false
		}
		if pane.State == "starting" && pane.LastEvent.IsZero() ||
			!pane.LastEvent.IsZero() && now.Sub(pane.LastEvent) < grace {
			return false
		}

		ss.SeenAt = now
		pane.State = "idle"
		pane.WorkingSince = time.Time{}
		ss.Panes["agent"] = pane
		changed = true
		return true
	})
	return changed, err
}

func updateExistingSessionState(id string, mutate func(*SessionState) bool) error {
	return updateExistingSessionStateAt(StateRoot(), id, mutate)
}

func updateExistingSessionStateAt(root, id string, mutate func(*SessionState) bool) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, id, func() error {
		ss, err := loadSessionStateAt(root, id)
		if err != nil || ss == nil {
			return err
		}
		if !mutate(ss) {
			return nil
		}
		return writeSessionStateLocked(root, id, ss)
	})
}

func writeSessionStateLocked(root, id string, ss *SessionState) error {
	if ss.SessionID == "" {
		ss.SessionID = id
	}
	if ss.Version == 0 {
		ss.Version = SchemaVersion
	}
	normalizeSessionState(ss)
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	data, err := json.Marshal(ss)
	if err != nil {
		return fmt.Errorf("marshal session state: %w", err)
	}
	data = append(data, '\n')
	path := SessionStatePath(root, id)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return fmt.Errorf("write tmp state: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename state.json: %w", err)
	}
	return nil
}

// InitStartingState seeds state.json with State="starting" / Activity="started"
// for each provided pane (roleName → agentName, e.g. {"agent": "codex"}).
// Skips any pane that already has a non-empty State so the agent's first
// hook (which fires moments later) is never overwritten. This eliminates
// the brief "unknown" the tracker would otherwise render between spawn and
// the SessionStart hook.
func InitStartingState(id string, agentsByRole map[string]string) error {
	if len(agentsByRole) == 0 {
		return nil
	}
	now := time.Now().UTC()
	return UpdateSessionState(id, func(ss *SessionState) bool {
		changed := false
		ss.SeenAt = now
		for role, agentName := range agentsByRole {
			if role == "" || agentName == "" {
				continue
			}
			if pane, ok := ss.Panes[role]; ok && pane.State != "" {
				continue
			}
			ss.Panes[role] = PaneState{
				Role:      role,
				Agent:     agentName,
				State:     "starting",
				Activity:  "started",
				LastKind:  "SessionStart",
				LastEvent: now,
				Seq:       now.UnixNano(),
			}
			changed = true
		}
		return changed
	})
}

// StateEvent is one line of state.jsonl. Free-form fields beyond the
// fixed columns belong in Fields so consumers parsing the log don't have
// to keep up with a moving schema.
type StateEvent struct {
	Ts        time.Time              `json:"ts"`
	Agent     string                 `json:"agent"`
	AgentID   string                 `json:"agent_id,omitempty"`
	AgentType string                 `json:"agent_type,omitempty"`
	Role      string                 `json:"role,omitempty"`
	Action    string                 `json:"action"`
	State     string                 `json:"state,omitempty"`
	Activity  string                 `json:"activity,omitempty"`
	Tool      string                 `json:"tool,omitempty"`
	Kind      string                 `json:"kind,omitempty"`
	Fields    map[string]interface{} `json:"fields,omitempty"`
}

// AppendStateEvent appends to state.jsonl and rotates the file when it
// crosses StateJSONLMaxSize. The state root must already exist (the
// session-state directory is created lazily). Rotation drops the previous
// .1 file, so only one rolled file is retained on disk.
func AppendStateEvent(id string, ev StateEvent) error {
	return AppendStateEventAt(StateRoot(), id, ev)
}

// AppendStateEventAt appends an event under the given state root.
func AppendStateEventAt(root, id string, ev StateEvent) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	return appendStateEventAt(root, id, ev)
}

func appendStateEventAt(root, id string, ev StateEvent) error {
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	return withFileLock(SessionStateLockPath(root, id), func() error {
		return appendRotatingJSONL(SessionStateLogPath(root, id), ev)
	})
}

func appendRotatingJSONL(path string, ev StateEvent) error {
	data, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("encode state event: %w", err)
	}
	return appendRotatingLine(path, append(data, '\n'))
}

// AppendHookError appends one timestamped line to the session's
// hook-errors.log. Agents discard a hook's stderr, so this file is where a
// failed hook leaves its trace when the session state directory exists. It
// does not create that directory, which may have been deleted with the session.
// It takes no state lock, so a hook that timed out waiting for that lock can
// still log, and it rotates like state.jsonl.
func AppendHookError(id, text string) error {
	return AppendHookErrorAt(StateRoot(), id, text)
}

// AppendHookErrorAt is AppendHookError with the state root supplied by the
// caller.
func AppendHookErrorAt(root, id, text string) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if root == "" {
		return errors.New("no state root resolved")
	}
	line := time.Now().UTC().Format(time.RFC3339Nano) + " " + strings.TrimRight(text, "\n") + "\n"
	return appendRotatingLine(SessionHookErrorLogPath(root, id), []byte(line))
}

// appendRotatingLine appends data to path and rotates the file to path.1 once
// it reaches StateJSONLMaxSize, keeping one rolled file.
func appendRotatingLine(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("open state log: %w", err)
	}
	defer f.Close()
	// Check the rotation threshold from the open fd (fstat) rather than a
	// separate os.Stat of the same path. When over the threshold, close this
	// handle, rotate, and reopen the fresh file so the append lands in it.
	if info, err := f.Stat(); err == nil && info.Size() >= StateJSONLMaxSize {
		f.Close()
		_ = os.Remove(path + ".1")
		_ = os.Rename(path, path+".1")
		f, err = os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
		if err != nil {
			return fmt.Errorf("open state log: %w", err)
		}
		defer f.Close()
	}
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("write state event: %w", err)
	}
	return nil
}

func withFileLock(lockPath string, fn func() error) error {
	return withFileLockContext(context.Background(), lockPath, fn)
}

// withFileLockContext is withFileLock with the wait bounded by ctx's
// deadline, as lockFile describes.
func withFileLockContext(ctx context.Context, lockPath string, fn func() error) error {
	unlock, err := lockFile(ctx, lockPath)
	if err != nil {
		return fmt.Errorf("acquire lock %s: %w", filepath.Base(lockPath), err)
	}
	defer unlock()
	return fn()
}

// lockFile opens lockPath, creating it, and takes an exclusive flock on it.
// unlock releases the lock and closes the file.
//
// The flock is always a blocking LOCK_EX, so waiters queue in the kernel. On
// macOS the kernel can take tens of ms to hand over a dropped flock; a
// LOCK_NB + sleep poll loop showed ~200ms p99 tail outliers. A 2 ms poll
// loop, tried in 2026-11 to give hooks a deadline, also starved waiters:
// with nine hooks on one session, p99 reached ~1 s and some hooks hit the
// deadline and skipped their state write.
//
// With a deadline on ctx, the blocking flock runs in a goroutine and the
// caller stops waiting at the deadline with ctx's error. The flock cannot be
// cancelled, so it stays queued and is released as soon as it is granted;
// the file stays open until then, so its descriptor is not reused under the
// waiting call. A hook exits right after, which drops it anyway.
func lockFile(ctx context.Context, lockPath string) (func(), error) {
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open: %w", err)
	}
	fd := int(f.Fd())
	unlock := func() {
		syscall.Flock(fd, syscall.LOCK_UN) //nolint:errcheck
		f.Close()
	}
	if _, bounded := ctx.Deadline(); !bounded {
		if err := syscall.Flock(fd, syscall.LOCK_EX); err != nil {
			f.Close()
			return nil, err
		}
		return unlock, nil
	}
	granted := make(chan error, 1)
	go func() { granted <- syscall.Flock(fd, syscall.LOCK_EX) }()
	select {
	case err := <-granted:
		if err != nil {
			f.Close()
			return nil, err
		}
		return unlock, nil
	case <-ctx.Done():
		go func() {
			if <-granted == nil {
				unlock()
				return
			}
			f.Close()
		}()
		return nil, ctx.Err()
	}
}

// withStateLock runs fn holding the per-session state lock, however long the
// wait. Hooks use withStateLockContext with their deadline.
func withStateLock(root, id string, fn func() error) error {
	return withStateLockContext(context.Background(), root, id, fn)
}

// withStateLockContext acquires an exclusive flock on the per-session
// lockfile and runs fn while holding it. The lockfile is created on first
// use. A deadline on ctx bounds the wait (lockFile); there is no deadlock to
// guard against otherwise (no recursive locking; defer-unlock on every path).
func withStateLockContext(ctx context.Context, root, id string, fn func() error) error {
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	unlock, err := lockFile(ctx, SessionStateLockPath(root, id))
	if err != nil {
		return fmt.Errorf("acquire state lock for %s: %w", id, err)
	}
	defer unlock()
	return fn()
}

func ensureSessionStateDir(root, id string) error {
	dir := SessionStateDir(root, id)
	if _, ok := ensuredSessionStateDirs.Load(dir); ok {
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			return nil
		}
	}
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("restrict session state dir: %w", err)
	}
	ensuredSessionStateDirs.Store(dir, struct{}{})
	return nil
}
