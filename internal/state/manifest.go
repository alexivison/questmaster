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

// validResumeID matches the shape of all resume IDs Claude Code / Codex
// produce (UUIDs, ULIDs, dashed hex). Anything else — path separators,
// glob metacharacters, null bytes, spaces — is blanked out at deserialize
// time so downstream consumers can interpolate the value into filesystem
// or glob patterns without guarding against injection.
var validResumeID = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// sanitizeResumeID returns v unchanged when it's a safe identifier, or
// "" when it contains characters that could escape filesystem / glob
// contexts (path traversal, wildcards, NUL, etc.).
func sanitizeResumeID(v string) string {
	if v == "" {
		return ""
	}
	if validResumeID.MatchString(v) {
		return v
	}
	return ""
}

// Manifest represents a party session's persisted state.
// JSON field names match the existing bash manifest schema in session/party-lib.sh.
// Extra holds unknown fields to preserve round-trip fidelity with bash writers.
type Manifest struct {
	PartyID     string          `json:"party_id"`
	CreatedAt   string          `json:"created_at,omitempty"`
	UpdatedAt   string          `json:"updated_at,omitempty"`
	Title       string          `json:"title,omitempty"`
	Cwd         string          `json:"cwd,omitempty"`
	WindowName  string          `json:"window_name,omitempty"`
	Agents      []AgentManifest `json:"agents,omitempty"`
	AgentPath   string          `json:"agent_path,omitempty"`
	SessionType string          `json:"session_type,omitempty"`
	Workers     []string        `json:"workers,omitempty"`

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

// UnmarshalJSON preserves unknown fields in Extra.
func (m *Manifest) UnmarshalJSON(data []byte) error {
	dec := json.NewDecoder(bytes.NewReader(data))

	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '{' {
		return fmt.Errorf("manifest must be a JSON object")
	}

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return err
		}

		key, ok := tok.(string)
		if !ok {
			return fmt.Errorf("manifest field name must be a string")
		}

		if err := m.decodeField(dec, key); err != nil {
			return err
		}
	}

	tok, err = dec.Token()
	if err != nil {
		return err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '}' {
		return fmt.Errorf("manifest must end with a JSON object")
	}

	if err := ensureEOF(dec); err != nil {
		return err
	}

	// Defense in depth: sanitize every resume ID before the manifest is
	// handed to consumers that splice it into filesystem paths or glob
	// patterns. A malformed value is blanked out rather than rejected so
	// the session remains usable; only the activity indicator goes dark.
	for i := range m.Agents {
		m.Agents[i].ResumeID = sanitizeResumeID(m.Agents[i].ResumeID)
	}
	for _, key := range []string{"claude_session_id", "codex_thread_id"} {
		value := m.ExtraString(key)
		if clean := sanitizeResumeID(value); clean != value {
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

func (m *Manifest) decodeField(dec *json.Decoder, key string) error {
	switch key {
	case "party_id":
		return dec.Decode(&m.PartyID)
	case "created_at":
		return dec.Decode(&m.CreatedAt)
	case "updated_at":
		return dec.Decode(&m.UpdatedAt)
	case "title":
		return dec.Decode(&m.Title)
	case "cwd":
		return dec.Decode(&m.Cwd)
	case "window_name":
		return dec.Decode(&m.WindowName)
	case "agents":
		return dec.Decode(&m.Agents)
	case "agent_path":
		return dec.Decode(&m.AgentPath)
	case "session_type":
		return dec.Decode(&m.SessionType)
	case "workers":
		return dec.Decode(&m.Workers)
	default:
		if m.Extra == nil {
			m.Extra = make(map[string]json.RawMessage)
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return err
		}
		m.Extra[key] = raw
		return nil
	}
}

func ensureEOF(dec *json.Decoder) error {
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("unexpected JSON value after manifest object")
		}
		return err
	}
	return nil
}

func (m Manifest) marshalFields() (map[string]json.RawMessage, error) {
	fields := make(map[string]json.RawMessage, len(m.Extra)+10)

	if err := marshalField(fields, "party_id", m.PartyID); err != nil {
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
