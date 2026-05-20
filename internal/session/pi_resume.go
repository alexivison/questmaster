//go:build linux || darwin

package session

import (
	"path/filepath"
	"regexp"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

var (
	piSessionFile    = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z_([A-Za-z0-9_-]+)\.jsonl$`)
	piSessionUUIDish = regexp.MustCompile(`^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$`)
)

// persistPiResumeFromActivity captures Pi's real resume UUID from hook state
// and stores it in both the typed agent entry and legacy extra field.
func (s *Service) persistPiResumeFromActivity(sessionID string) (string, error) {
	return persistPiResumeFromActivity(s.Store, sessionID)
}

func persistPiResumeFromActivity(store *state.Store, sessionID string) (string, error) {
	resumeID, ok := readPiResumeID(sessionID)
	if !ok {
		return "", nil
	}

	m, err := store.Read(sessionID)
	if err != nil {
		return "", err
	}
	if !hasPiAgent(m) {
		return "", nil
	}
	if piResumePersisted(m, resumeID) {
		return resumeID, nil
	}

	if err := store.Update(sessionID, func(m *state.Manifest) {
		for i := range m.Agents {
			if m.Agents[i].Name == "pi" {
				m.Agents[i].ResumeID = resumeID
			}
		}
		m.SetExtra("pi_session_id", resumeID)
	}); err != nil {
		return "", err
	}
	return resumeID, nil
}

func readPiResumeID(sessionID string) (string, bool) {
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil || ss.Version != state.SchemaVersion {
		return "", false
	}
	pane, ok := ss.Panes["primary"]
	if !ok || (pane.Agent != "" && pane.Agent != "pi") {
		return "", false
	}
	if id := cleanPiResumeID(pane.PiSessionID); id != "" {
		return id, true
	}
	if id := piResumeIDFromSessionFile(pane.SessionFile); id != "" {
		return id, true
	}
	return "", false
}

func piResumeIDFromSessionFile(sessionFile string) string {
	sessionFile = strings.TrimSpace(sessionFile)
	if sessionFile == "" {
		return ""
	}
	match := piSessionFile.FindStringSubmatch(filepath.Base(sessionFile))
	if len(match) != 2 {
		return ""
	}
	return cleanPiResumeID(match[1])
}

func cleanPiResumeID(id string) string {
	id = strings.TrimSpace(id)
	if id == "" || !piSessionUUIDish.MatchString(id) {
		return ""
	}
	return state.SanitizeResumeID(id)
}

func hasPiAgent(m state.Manifest) bool {
	for _, spec := range m.Agents {
		if spec.Name == "pi" {
			return true
		}
	}
	return false
}

func piResumePersisted(m state.Manifest, resumeID string) bool {
	if m.ExtraString("pi_session_id") != resumeID {
		return false
	}
	for _, spec := range m.Agents {
		if spec.Name == "pi" && spec.ResumeID != resumeID {
			return false
		}
	}
	return true
}
