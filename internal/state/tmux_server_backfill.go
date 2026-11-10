package state

import "os"

// BackfillTmuxServer records dedicated ownership without renewing the manifest's
// age. The caller must hold the lifecycle lock and have proved the session is
// stopped. The manifest lock preserves concurrent resume-ID and metadata writes.
func (s *Store) BackfillTmuxServer(sessionID string) (bool, error) {
	if err := s.validateID(sessionID); err != nil {
		return false, err
	}
	updated := false
	err := s.withLock(sessionID, func() error {
		path := s.manifestPath(sessionID)
		m, err := s.readManifest(path)
		if err != nil {
			return err
		}
		if m.TmuxServer != "" && m.TmuxServer != "default" {
			return nil
		}
		info, err := os.Stat(path)
		if err != nil {
			return err
		}
		modTime := info.ModTime()
		m.SessionID = sessionID
		m.TmuxServer = "questmaster"
		if err := s.writeManifestWithTimestamps(path, m, false, &modTime); err != nil {
			return err
		}
		updated = true
		return nil
	})
	return updated, err
}
