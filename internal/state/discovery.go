//go:build linux || darwin

package state

import (
	"os"
	"path/filepath"
	"strings"
)

// DiscoverSessions returns all party session manifests found in the state root.
// Non-party files, lock files, and corrupt manifests are silently skipped.
func (s *Store) DiscoverSessions() ([]Manifest, error) {
	entries, err := os.ReadDir(s.root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var sessions []Manifest
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".json") || strings.HasSuffix(name, ".lock") {
			continue
		}

		partyID := strings.TrimSuffix(name, ".json")
		if !strings.HasPrefix(partyID, "party-") {
			continue
		}

		m, err := s.readManifest(filepath.Join(s.root, name))
		if err != nil {
			continue // skip corrupt manifests
		}
		m.PartyID = partyID // filename is canonical, not JSON content
		sessions = append(sessions, m)
	}

	return sessions, nil
}
