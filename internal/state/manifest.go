// Package state provides manifest CRUD, locking, and session discovery.
package state

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"sort"
	"time"
)

// validResumeID matches the shape of all resume IDs Claude Code, Codex,
// Pi, omp, and OpenCode produce (UUIDs, ULIDs, dashed hex). Anything else — path separators,
// glob metacharacters, null bytes, spaces — is blanked out at deserialize
// time so downstream consumers can interpolate the value into filesystem
// or glob patterns without guarding against injection.
var validResumeID = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// SanitizeResumeID returns v unchanged when it's a safe identifier, or
// "" when it contains characters that could escape filesystem / glob
// contexts (path traversal, wildcards, NUL, etc.). Exported so downstream
// consumers share the single source of truth rather than carrying their own
// copy of the regex.
func SanitizeResumeID(v string) string {
	if v == "" {
		return ""
	}
	if validResumeID.MatchString(v) {
		return v
	}
	return ""
}

// Manifest represents a questmaster session's persisted state.
// Extra holds unknown fields to preserve fields this version does not interpret.
type Manifest struct {
	SessionID   string           `json:"session_id"`
	CreatedAt   string           `json:"created_at,omitempty"`
	UpdatedAt   string           `json:"updated_at,omitempty"`
	Title       string           `json:"title,omitempty"`
	Cwd         string           `json:"cwd,omitempty"`
	WindowName  string           `json:"window_name,omitempty"`
	Agents      []AgentManifest  `json:"agents,omitempty"`
	AgentPath   string           `json:"agent_path,omitempty"`
	SessionType string           `json:"session_type,omitempty"`
	Workers     []string         `json:"workers,omitempty"`
	Display     *DisplayMetadata `json:"display,omitempty"`

	// Extra preserves unknown fields written by bash helpers
	// (e.g. parent_session, initial_prompt).
	Extra map[string]json.RawMessage `json:"-"`
}

// AgentManifest stores per-agent runtime state in the manifest.
type AgentManifest struct {
	Name     string `json:"name"`
	Role     string `json:"role"`
	CLI      string `json:"cli"`
	ResumeID string `json:"resume_id,omitempty"`
	Window   int    `json:"window"`
}

// knownManifestKeys is the set of JSON keys mapped to typed Manifest fields.
// Every other key in a manifest object is preserved verbatim in Extra. Kept in
// sync with the struct tags above.
var knownManifestKeys = map[string]struct{}{
	"session_id": {}, "created_at": {}, "updated_at": {}, "title": {},
	"cwd": {}, "window_name": {}, "agents": {}, "agent_path": {},
	"session_type": {}, "workers": {}, "display": {},
}

// UnmarshalJSON preserves unknown fields in Extra. It decodes the typed fields
// in one pass (encoding/json's optimized struct path) and captures unknown keys
// in a second shallow pass into RawMessage — far cheaper than the previous
// token-stream loop, which re-entered the reflection decoder per field and
// boxed every delimiter through Token().
func (m *Manifest) UnmarshalJSON(data []byte) error {
	// plain drops Manifest's methods (no recursion) and, via the json:"-" tag on
	// Extra, decodes only the typed fields.
	type plain Manifest
	var p plain
	if err := json.Unmarshal(data, &p); err != nil {
		return err
	}
	*m = Manifest(p)

	// Second pass: capture every key, then drop the ones already bound to a
	// typed field. RawMessage captures bytes without parsing the value subtree,
	// so unknown nested objects/arrays cost one allocation each, not a deep walk.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for key := range raw {
		if _, known := knownManifestKeys[key]; known {
			delete(raw, key)
		}
	}
	if len(raw) > 0 {
		m.Extra = raw
	}

	// Defense in depth: sanitize every resume ID before the manifest is
	// handed to consumers that splice it into filesystem paths or glob
	// patterns. A malformed value is blanked out rather than rejected so
	// the session remains usable; only the activity indicator goes dark.
	for i := range m.Agents {
		m.Agents[i].ResumeID = SanitizeResumeID(m.Agents[i].ResumeID)
	}
	for _, key := range []string{"claude_session_id", "codex_thread_id", "pi_session_id", "omp_session_id", "opencode_session_id"} {
		value := m.ExtraString(key)
		if clean := SanitizeResumeID(value); clean != value {
			if clean == "" {
				delete(m.Extra, key)
			} else {
				m.SetExtra(key, clean)
			}
		}
	}
	return nil
}

// MarshalJSON merges typed fields with Extra to preserve unknown keys.
func (m Manifest) MarshalJSON() ([]byte, error) {
	type plain Manifest
	if len(m.Extra) == 0 {
		return json.Marshal(plain(m))
	}

	fields, err := m.marshalFields()
	if err != nil {
		return nil, err
	}
	return marshalObject(fields)
}

// ExtraString reads a string value from the manifest's Extra map.
func (m Manifest) ExtraString(key string) string {
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

// SetExtra sets a string value in the manifest's Extra map.
func (m *Manifest) SetExtra(key, value string) {
	if m.Extra == nil {
		m.Extra = make(map[string]json.RawMessage)
	}
	raw, _ := json.Marshal(value)
	m.Extra[key] = raw
}

// NowUTC returns the current time in the format used by bash manifest helpers.
func NowUTC() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

// ensureEOF confirms a decoder has consumed exactly one JSON value, rejecting
// trailing data. Shared with the DisplayMetadata decoder in display.go.
func ensureEOF(dec *json.Decoder) error {
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("unexpected JSON value after object")
		}
		return err
	}
	return nil
}

func (m Manifest) marshalFields() (map[string]json.RawMessage, error) {
	fields := make(map[string]json.RawMessage, len(m.Extra)+10)

	if err := marshalField(fields, "session_id", m.SessionID); err != nil {
		return nil, err
	}
	if m.CreatedAt != "" {
		if err := marshalField(fields, "created_at", m.CreatedAt); err != nil {
			return nil, err
		}
	}
	if m.UpdatedAt != "" {
		if err := marshalField(fields, "updated_at", m.UpdatedAt); err != nil {
			return nil, err
		}
	}
	if m.Title != "" {
		if err := marshalField(fields, "title", m.Title); err != nil {
			return nil, err
		}
	}
	if m.Cwd != "" {
		if err := marshalField(fields, "cwd", m.Cwd); err != nil {
			return nil, err
		}
	}
	if m.WindowName != "" {
		if err := marshalField(fields, "window_name", m.WindowName); err != nil {
			return nil, err
		}
	}
	if len(m.Agents) > 0 {
		if err := marshalField(fields, "agents", m.Agents); err != nil {
			return nil, err
		}
	}
	if m.AgentPath != "" {
		if err := marshalField(fields, "agent_path", m.AgentPath); err != nil {
			return nil, err
		}
	}
	if m.SessionType != "" {
		if err := marshalField(fields, "session_type", m.SessionType); err != nil {
			return nil, err
		}
	}
	if len(m.Workers) > 0 {
		if err := marshalField(fields, "workers", m.Workers); err != nil {
			return nil, err
		}
	}
	if m.Display != nil && !m.Display.IsZero() {
		if err := marshalField(fields, "display", m.Display); err != nil {
			return nil, err
		}
	}

	for key, raw := range m.Extra {
		if _, exists := fields[key]; exists {
			continue
		}
		fields[key] = raw
	}

	return fields, nil
}

func marshalField(fields map[string]json.RawMessage, key string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	fields[key] = raw
	return nil
}

func marshalObject(fields map[string]json.RawMessage) ([]byte, error) {
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, key := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}

		rawKey, err := json.Marshal(key)
		if err != nil {
			return nil, err
		}
		buf.Write(rawKey)
		buf.WriteByte(':')

		raw := fields[key]
		if raw == nil {
			buf.WriteString("null")
			continue
		}
		buf.Write(raw)
	}
	buf.WriteByte('}')

	return buf.Bytes(), nil
}
