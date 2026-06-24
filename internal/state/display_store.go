//go:build linux || darwin

package state

import (
	"fmt"
	"strings"
)

// SetDisplayColor updates a non-worker session's display color in its manifest.
// Empty color clears the override so the row falls back to repo/default color.
// Unknown display.* keys are preserved by mutating DisplayMetadata in place.
func (s *Store) SetDisplayColor(sessionID, color string) error {
	color = strings.TrimSpace(color)
	if color != "" && !IsDisplayColor(color) {
		return fmt.Errorf("invalid color %q", color)
	}
	return s.Update(sessionID, func(m *Manifest) {
		if manifestIsWorker(*m) {
			return
		}
		if color == "" {
			if m.Display == nil {
				return
			}
			m.Display.Color = ""
			m.Display.ColorChangedAt = ""
			if m.Display.IsZero() {
				m.Display = nil
			}
			return
		}
		if m.Display == nil {
			m.Display = NewDisplayMetadata(color)
		} else {
			m.Display.Color = NormalizeDisplayColor(color)
		}
		m.Display.ColorChangedAt = NowColorStamp()
	})
}

func manifestIsWorker(m Manifest) bool {
	return m.SessionType != "master" && m.ExtraString("parent_session") != ""
}
