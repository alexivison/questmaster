//go:build linux || darwin

package session

import (
	"github.com/anthropics/ai-party/tools/party-cli/internal/piactivity"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
)

// persistPiResumeFromActivity captures Pi's real resume UUID from the activity
// sidecar and stores it in both the typed agent entry and legacy extra field.
func (s *Service) persistPiResumeFromActivity(sessionID string) (string, error) {
	return persistPiResumeFromActivity(s.Store, sessionID)
}

func persistPiResumeFromActivity(store *state.Store, sessionID string) (string, error) {
	resumeID, ok := piactivity.ReadResumeID(sessionID)
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
