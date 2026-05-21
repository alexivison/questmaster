//go:build linux || darwin

package state

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
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

// SessionState is the authoritative per-session state snapshot written by
// hooks and read by the tracker. One file per session at
// <state_root>/<session_id>/state.json.
type SessionState struct {
	SessionID string               `json:"session_id"`
	Version   int                  `json:"version"`
	Panes     map[string]PaneState `json:"panes"`
	SeenAt    time.Time            `json:"seen_at"`
}

// PaneState is the renderer-visible state for one role (primary or
// companion) within a session. Pi-specific carry-through fields are
// populated only when Agent == "pi"; see PLAN.md "Pi sidecar contract".
type PaneState struct {
	Role      string    `json:"role"`
	Agent     string    `json:"agent"`
	State     string    `json:"state"`
	Activity  string    `json:"activity"`
	Tool      string    `json:"tool,omitempty"`
	Seq       int64     `json:"seq"`
	LastEvent time.Time `json:"last_event"`
	LastKind  string    `json:"last_kind"`

	Recent      []string `json:"recent,omitempty"`
	SessionFile string   `json:"session_file,omitempty"`
	PiSessionID string   `json:"pi_session_id,omitempty"`
}

// StateRoot resolves the directory that holds per-session state. Honors
// $PARTY_STATE_ROOT, falls back to ~/.party-state. Returns the empty
// string when neither $PARTY_STATE_ROOT nor $HOME is set (caller treats
// that as a no-op condition).
func StateRoot() string {
	if root := os.Getenv("PARTY_STATE_ROOT"); root != "" {
		return root
	}
	if home := os.Getenv("HOME"); home != "" {
		return filepath.Join(home, ".party-state")
	}
	return ""
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

// SessionStateLockPath returns the flock path. We lock a sibling file
// rather than state.json itself so the atomic rename of state.json never
// races a still-held lock fd.
func SessionStateLockPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.json.lock")
}

// LoadSessionState reads the state.json for a session. Returns (nil, nil)
// if the file does not exist (the renderer should treat this as
// "unknown"). The state root is resolved from $PARTY_STATE_ROOT / $HOME.
func LoadSessionState(id string) (*SessionState, error) {
	if !IsValidPartyID(id) {
		return nil, fmt.Errorf("invalid party id: %q", id)
	}
	root := StateRoot()
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
	if s.Panes == nil {
		s.Panes = map[string]PaneState{}
	}
	return &s, nil
}

// SaveSessionState writes the state.json for a session atomically. The
// write is serialized via flock on a sibling lockfile.
func SaveSessionState(id string, ss *SessionState) error {
	if !IsValidPartyID(id) {
		return fmt.Errorf("invalid party id: %q", id)
	}
	if ss == nil {
		return errors.New("nil session state")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved (set PARTY_STATE_ROOT or HOME)")
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
// the load happens outside the lock. See PLAN.md lines 417–455.
func UpdateSessionState(id string, mutate func(*SessionState) bool) error {
	if !IsValidPartyID(id) {
		return fmt.Errorf("invalid party id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, id, func() error {
		ss, err := loadSessionStateAt(root, id)
		if err != nil {
			return err
		}
		if ss == nil {
			ss = &SessionState{
				SessionID: id,
				Version:   SchemaVersion,
				Panes:     map[string]PaneState{},
			}
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
	if ss.Panes == nil {
		ss.Panes = map[string]PaneState{}
	}
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	data, err := json.Marshal(ss)
	if err != nil {
		return fmt.Errorf("marshal session state: %w", err)
	}
	data = append(data, '\n')
	path := SessionStatePath(root, id)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp state: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename state.json: %w", err)
	}
	return nil
}

// InitStartingState seeds state.json with State="starting" / Activity="started"
// for each provided pane (roleName → agentName, e.g. {"primary": "codex"}).
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
	Ts       time.Time              `json:"ts"`
	Agent    string                 `json:"agent"`
	Role     string                 `json:"role,omitempty"`
	Action   string                 `json:"action"`
	State    string                 `json:"state,omitempty"`
	Activity string                 `json:"activity,omitempty"`
	Tool     string                 `json:"tool,omitempty"`
	Kind     string                 `json:"kind,omitempty"`
	Fields   map[string]interface{} `json:"fields,omitempty"`
}

// AppendStateEvent appends to state.jsonl and rotates the file when it
// crosses StateJSONLMaxSize. The state root must already exist (the
// session-state directory is created lazily). Rotation drops the previous
// .1 file, so only one rolled file is retained on disk.
func AppendStateEvent(id string, ev StateEvent) error {
	if !IsValidPartyID(id) {
		return fmt.Errorf("invalid party id: %q", id)
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return appendStateEventAt(root, id, ev)
}

func appendStateEventAt(root, id string, ev StateEvent) error {
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	logPath := SessionStateLogPath(root, id)
	if info, err := os.Stat(logPath); err == nil && info.Size() >= StateJSONLMaxSize {
		// Rotate by overwriting any existing .1 file. Ignore errors:
		// rotation is best-effort and must not block the hot path.
		_ = os.Rename(logPath, logPath+".1")
	}
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open state log: %w", err)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	if err := json.NewEncoder(w).Encode(ev); err != nil {
		return fmt.Errorf("encode state event: %w", err)
	}
	return w.Flush()
}

// withStateLock acquires an exclusive flock on the per-session lockfile
// and runs fn while holding it. The lockfile is created on first use.
//
// We use plain blocking flock (LOCK_EX) rather than a LOCK_NB + sleep
// poll loop. On macOS the kernel can take tens of ms to release a
// dropped flock after the holding process exits; polling with LOCK_NB
// pays back-to-back scheduler pauses that show up as ~200ms p99 tail
// outliers. Blocking LOCK_EX is kernel-driven and adds <1ms in the
// uncontended case.
//
// There is no userspace timeout: deadlock is impossible (no recursive
// locking; defer-unlock on every path). If the kernel were to hang the
// lock, the agent's own hook timeout (Claude: 5s by default) is the
// outer cap.
func withStateLock(root, id string, fn func() error) error {
	dir := SessionStateDir(root, id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	lockPath := SessionStateLockPath(root, id)
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open state lock: %w", err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire state lock for %s: %w", id, err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return fn()
}
