// Package state provides manifest CRUD, locking, and session discovery.
package state

import (
	"encoding/json"
	"time"
)

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
	ClaudeBin   string          `json:"claude_bin,omitempty"`
	CodexBin    string          `json:"codex_bin,omitempty"`
	Agents      []AgentManifest `json:"agents,omitempty"`
	AgentPath   string          `json:"agent_path,omitempty"`
	SessionType string          `json:"session_type,omitempty"`
	Workers     []string        `json:"workers,omitempty"`

	// Extra preserves unknown fields written by bash helpers
	// (e.g. parent_session, initial_prompt, claude_session_id).
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

// knownKeys lists JSON keys handled by typed struct fields.
var knownKeys = map[string]bool{
	"party_id": true, "created_at": true, "updated_at": true,
	"title": true, "cwd": true, "window_name": true,
	"claude_bin": true, "codex_bin": true, "agents": true, "agent_path": true,
	"session_type": true, "workers": true,
}

// UnmarshalJSON preserves unknown fields in Extra.
func (m *Manifest) UnmarshalJSON(data []byte) error {
	// Alias to avoid recursion.
	type plain Manifest
	if err := json.Unmarshal(data, (*plain)(m)); err != nil {
		return err
	}

	// Collect unknown keys.
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	for k, v := range raw {
		if knownKeys[k] {
			continue
		}
		if m.Extra == nil {
			m.Extra = make(map[string]json.RawMessage)
		}
		m.Extra[k] = v
	}

	if len(m.Agents) == 0 {
		if m.ClaudeBin != "" || m.ExtraString("claude_session_id") != "" {
			claudeWindow := 1
			if m.SessionType == "master" {
				claudeWindow = 0
			}
			m.Agents = append(m.Agents, AgentManifest{
				Name:     "claude",
				Role:     "primary",
				CLI:      m.ClaudeBin,
				ResumeID: m.ExtraString("claude_session_id"),
				Window:   claudeWindow,
			})
		}
		if m.CodexBin != "" || m.ExtraString("codex_thread_id") != "" {
			m.Agents = append(m.Agents, AgentManifest{
				Name:     "codex",
				Role:     "companion",
				CLI:      m.CodexBin,
				ResumeID: m.ExtraString("codex_thread_id"),
				Window:   0,
			})
		}
	}
	return nil
}

// MarshalJSON merges typed fields with Extra to preserve unknown keys.
func (m Manifest) MarshalJSON() ([]byte, error) {
	type plain Manifest
	data, err := json.Marshal(plain(m))
	if err != nil {
		return nil, err
	}
	if len(m.Extra) == 0 {
		return data, nil
	}

	// Merge Extra into the JSON object.
	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err != nil {
		return nil, err
	}
	for k, v := range m.Extra {
		if _, exists := obj[k]; !exists {
			obj[k] = v
		}
	}
	return json.Marshal(obj)
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
