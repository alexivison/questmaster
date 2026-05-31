//go:build linux || darwin

package session

import (
	"path/filepath"
	"regexp"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

// ompSessionID matches an oh-my-pi session id. Unlike Pi's UUID, omp ids are
// short alphanumeric tokens (e.g. "1f9d2a6b9c0d1234"), so the validator is a
// length-bounded alphanumeric class rather than the UUID shape pi_resume uses.
var ompSessionID = regexp.MustCompile(`^[A-Za-z0-9]{8,64}$`)

// persistOmpResumeFromActivity captures omp's resume id from hook state and
// stores it in both the typed agent entry and the legacy extra field. It is
// the omp analogue of persistPiResumeFromActivity: omp does not expose its
// session id via an environment variable, so the activity sidecar surfaces it
// through the session-file path (or PiSessionID carry-through field) instead.
func (s *Service) persistOmpResumeFromActivity(sessionID string) (string, error) {
	return persistOmpResumeFromActivity(s.Store, sessionID)
}

func persistOmpResumeFromActivity(store *state.Store, sessionID string) (string, error) {
	resumeID, ok := readOmpResumeID(sessionID)
	if !ok {
		return "", nil
	}

	m, err := store.Read(sessionID)
	if err != nil {
		return "", err
	}
	if !hasOmpAgent(m) {
		return "", nil
	}
	if ompResumePersisted(m, resumeID) {
		return resumeID, nil
	}

	if err := store.Update(sessionID, func(m *state.Manifest) {
		for i := range m.Agents {
			if m.Agents[i].Name == "omp" {
				m.Agents[i].ResumeID = resumeID
			}
		}
		m.SetExtra("omp_session_id", resumeID)
	}); err != nil {
		return "", err
	}
	return resumeID, nil
}

func readOmpResumeID(sessionID string) (string, bool) {
	ss, err := state.LoadSessionState(sessionID)
	if err != nil || ss == nil || ss.Version != state.SchemaVersion {
		return "", false
	}
	pane, ok := ss.Panes["primary"]
	if !ok || (pane.Agent != "" && pane.Agent != "omp") {
		return "", false
	}
	// The sidecar may surface the id directly via the generic PiSessionID
	// carry-through field; otherwise derive it from the session-file name.
	if id := cleanOmpResumeID(pane.PiSessionID); id != "" {
		return id, true
	}
	if id := ompResumeIDFromSessionFile(pane.SessionFile); id != "" {
		return id, true
	}
	return "", false
}

// ompResumeIDFromSessionFile extracts the session id from an omp session-file
// path of the form ".../<timestamp>_<sessionId>.jsonl". It splits on the last
// underscore rather than matching an exact timestamp so it stays robust to
// timestamp-format changes between omp releases.
func ompResumeIDFromSessionFile(sessionFile string) string {
	sessionFile = strings.TrimSpace(sessionFile)
	if sessionFile == "" {
		return ""
	}
	base := filepath.Base(sessionFile)
	if !strings.HasSuffix(base, ".jsonl") {
		return ""
	}
	base = strings.TrimSuffix(base, ".jsonl")
	if idx := strings.LastIndex(base, "_"); idx >= 0 {
		base = base[idx+1:]
	}
	return cleanOmpResumeID(base)
}

func cleanOmpResumeID(id string) string {
	id = strings.TrimSpace(id)
	if id == "" || !ompSessionID.MatchString(id) {
		return ""
	}
	return state.SanitizeResumeID(id)
}

func hasOmpAgent(m state.Manifest) bool {
	for _, spec := range m.Agents {
		if spec.Name == "omp" {
			return true
		}
	}
	return false
}

func ompResumePersisted(m state.Manifest, resumeID string) bool {
	if m.ExtraString("omp_session_id") != resumeID {
		return false
	}
	for _, spec := range m.Agents {
		if spec.Name == "omp" && spec.ResumeID != resumeID {
			return false
		}
	}
	return true
}
