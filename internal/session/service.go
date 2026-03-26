// Package session manages lifecycle operations (start, stop, continue, promote, spawn).
package session

import (
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

// runtimeDir returns the runtime directory path for a session.
// Uses /tmp/ (not os.TempDir()) to match party-lib.sh and the cleanup script,
// which both hardcode /tmp/. On macOS, os.TempDir() returns /var/folders/...
// which diverges from the bash convention and causes orphaned runtime dirs.
func runtimeDir(sessionID string) string {
	return filepath.Join("/tmp", sessionID)
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

// sessionRole identifies a session's role for window naming.
type sessionRole string

const (
	roleStandalone sessionRole = ""
	roleMaster     sessionRole = "master"
	roleWorker     sessionRole = "worker"
)

// windowName generates a tmux window name from a title and role.
func windowName(title string, role sessionRole) string {
	base := "work"
	if title != "" {
		base = fmt.Sprintf("party (%s)", title)
	}
	switch role {
	case roleMaster:
		return base + " [master]"
	case roleWorker:
		return base + " [worker]"
	default:
		return base
	}
}

// resolveCLICmd resolves the party-cli launch command using the service's resolver.
func (s *Service) resolveCLICmd() (string, error) {
	return s.CLIResolver(s.RepoRoot)
}
