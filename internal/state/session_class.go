package state

import (
	"fmt"
	"os"
	"strings"
	"time"
)

var sessionClassNames = []string{"paladin", "wizard", "druid", "barbarian", "rogue", "cleric", "bard"}

var sessionClassSet = func() map[string]struct{} {
	set := make(map[string]struct{}, len(sessionClassNames))
	for _, class := range sessionClassNames {
		set[class] = struct{}{}
	}
	return set
}()

func ValidateSessionClass(class string) (string, error) {
	class = strings.ToLower(strings.TrimSpace(class))
	if _, ok := sessionClassSet[class]; ok {
		return class, nil
	}
	return "", fmt.Errorf("invalid class %q (want one of %s)", class, strings.Join(sessionClassNames, ", "))
}

// ChooseSessionClass selects uniformly among the classes with the lowest
// active count. randomIndex is injectable so callers and tests can control ties.
func ChooseSessionClass(activeClasses []string, randomIndex func(int) int) string {
	counts := make(map[string]int, len(sessionClassNames))
	for _, class := range activeClasses {
		if _, ok := sessionClassSet[class]; ok {
			counts[class]++
		}
	}

	lowest := counts[sessionClassNames[0]]
	for _, class := range sessionClassNames[1:] {
		if counts[class] < lowest {
			lowest = counts[class]
		}
	}

	choices := make([]string, 0, len(sessionClassNames))
	for _, class := range sessionClassNames {
		if counts[class] == lowest {
			choices = append(choices, class)
		}
	}
	return choices[randomIndex(len(choices))]
}

func (m Manifest) DisplayClass() string {
	if m.Display == nil {
		return ""
	}
	class, err := ValidateSessionClass(m.Display.Class)
	if err != nil {
		return ""
	}
	return class
}

// SetSessionClass changes the display class of a master session.
func (s *Store) SetSessionClass(sessionID, class string) error {
	class, err := ValidateSessionClass(class)
	if err != nil {
		return err
	}
	_, err = s.updateSessionClass(sessionID, class, false)
	return err
}

// SetSessionClassIfMissing persists class only when the master has none yet,
// returning the stored value if another snapshot already filled it.
func (s *Store) SetSessionClassIfMissing(sessionID, class string) (string, error) {
	class, err := ValidateSessionClass(class)
	if err != nil {
		return "", err
	}
	return s.updateSessionClass(sessionID, class, true)
}

func (s *Store) updateSessionClass(sessionID, class string, onlyIfMissing bool) (string, error) {
	if err := s.validateID(sessionID); err != nil {
		return "", err
	}
	var stored string
	err := s.withLock(sessionID, func() error {
		path := s.manifestPath(sessionID)
		m, err := s.readManifest(path)
		if err != nil {
			return err
		}
		switch m.AgentSessionType() {
		case "worker":
			return fmt.Errorf("cannot set class for worker session %s; workers inherit their master's class", sessionID)
		case "master":
		default:
			return fmt.Errorf("cannot set class for shell session %s; shell sessions have no class", sessionID)
		}

		if current := m.DisplayClass(); onlyIfMissing && current != "" {
			stored = current
			return nil
		}
		var oldModTime time.Time
		if onlyIfMissing {
			info, err := os.Stat(path)
			if err != nil {
				return err
			}
			oldModTime = info.ModTime()
		}
		if m.Display == nil {
			m.Display = &DisplayMetadata{}
		}
		m.Display.Class = class
		stored = class
		if err := s.writeManifestWithTimestamps(path, m, !onlyIfMissing); err != nil {
			return err
		}
		if onlyIfMissing {
			return os.Chtimes(path, oldModTime, oldModTime)
		}
		return nil
	})
	return stored, err
}
