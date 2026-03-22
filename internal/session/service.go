// Package session manages lifecycle operations (start, stop, continue, promote, spawn).
package session

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"time"

	"github.com/anthropics/ai-config/tools/party-cli/internal/config"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// Service provides session lifecycle operations backed by state and tmux.
type Service struct {
	Store    *state.Store
	Client   *tmux.Client
	RepoRoot string

	// CLIResolver resolves the party-cli launch command. Defaults to config.ResolvePartyCLICmd.
	CLIResolver func(repoRoot string) (string, error)
	// Now returns the current unix timestamp. Defaults to time.Now().Unix().
	Now func() int64
	// RandSuffix returns a random int for session ID dedup.
	RandSuffix func() int64
}

// NewService creates a session service with production defaults.
func NewService(store *state.Store, client *tmux.Client, repoRoot string) *Service {
	return &Service{
		Store:       store,
		Client:      client,
		RepoRoot:    repoRoot,
		CLIResolver: config.ResolvePartyCLICmd,
		Now:         func() int64 { return time.Now().Unix() },
		RandSuffix:  func() int64 { return rand.Int64N(100000) },
	}
}

// LayoutMode is the session pane layout style.
type LayoutMode string

const (
	LayoutClassic LayoutMode = "classic"
	LayoutSidebar LayoutMode = "sidebar"
)

// nowUTC returns ISO 8601 UTC timestamp.
func nowUTC() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

// runtimeDir returns the runtime directory path for a session.
func runtimeDir(sessionID string) string {
	return filepath.Join(os.TempDir(), sessionID)
}

// ensureRuntimeDir creates the runtime directory and writes the session name file.
func ensureRuntimeDir(sessionID string) (string, error) {
	dir := runtimeDir(sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create runtime dir: %w", err)
	}
	nameFile := filepath.Join(dir, "session-name")
	if err := os.WriteFile(nameFile, []byte(sessionID+"\n"), 0o644); err != nil {
		return "", fmt.Errorf("write session-name: %w", err)
	}
	return dir, nil
}

// removeRuntimeDir removes the runtime directory for a session.
func removeRuntimeDir(sessionID string) {
	os.RemoveAll(runtimeDir(sessionID))
}

// setExtraField sets a value in the manifest's Extra map.
func setExtraField(m *state.Manifest, key, value string) {
	if m.Extra == nil {
		m.Extra = make(map[string]json.RawMessage)
	}
	raw, _ := json.Marshal(value)
	m.Extra[key] = raw
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

// windowName generates a tmux window name from a title.
func windowName(title string) string {
	if title != "" {
		return fmt.Sprintf("party (%s)", title)
	}
	return "work"
}

// resolveCLICmd resolves the party-cli launch command using the service's resolver.
func (s *Service) resolveCLICmd() (string, error) {
	return s.CLIResolver(s.RepoRoot)
}
