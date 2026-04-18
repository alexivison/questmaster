//go:build linux || darwin

package state

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
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

// SortByMtime sorts manifests by file modification time, newest first.
func SortByMtime(manifests []Manifest, root string) {
	sort.Slice(manifests, func(i, j int) bool {
		mi := fileModTime(filepath.Join(root, manifests[i].PartyID+".json"))
		mj := fileModTime(filepath.Join(root, manifests[j].PartyID+".json"))
		return mi.After(mj)
	})
}

// TODO(dedup): duplicates agent/codex.go:statMTime. Consolidate in a
// shared fsutil package if a third caller appears.
func fileModTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}
