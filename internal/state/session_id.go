package state

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

const (
	// SessionIDPrefix is used for newly created questmaster sessions.
	SessionIDPrefix = "qm-"
	// LegacySessionIDPrefix is accepted for sessions created before qm-* IDs.
	// Deprecated: keep for compatibility with persisted manifests and tmux sessions.
	LegacySessionIDPrefix = "party-"

	// SessionEnv is the preferred environment variable for the current session ID.
	SessionEnv = "QUESTMASTER_SESSION"
	// LegacySessionEnv is still read for compatibility with older launches/hooks.
	// Deprecated: use SessionEnv.
	LegacySessionEnv = "PARTY_SESSION"

	// StateRootEnv is the preferred environment variable for the state root.
	StateRootEnv = "QUESTMASTER_STATE_ROOT"
	// LegacyStateRootEnv is still read for compatibility with older installs.
	// Deprecated: use StateRootEnv.
	LegacyStateRootEnv = "PARTY_STATE_ROOT"
)

var validSessionID = regexp.MustCompile(`^(?:qm|party)-[A-Za-z0-9_-]+$`)

// NewSessionID formats the base ID for a new questmaster session.
func NewSessionID(timestamp int64) string {
	return fmt.Sprintf("%s%d", SessionIDPrefix, timestamp)
}

// NewSessionIDWithSuffix formats a collision-retry ID for a new questmaster session.
func NewSessionIDWithSuffix(timestamp, suffix int64) string {
	return fmt.Sprintf("%s%d-%d", SessionIDPrefix, timestamp, suffix)
}

// IsValidSessionID reports whether id is a supported questmaster session ID.
// qm-* is the canonical prefix; legacy party-* remains accepted for compatibility.
func IsValidSessionID(id string) bool {
	return validSessionID.MatchString(id)
}

// IsValidPartyID reports whether id is a supported session ID.
// Deprecated: use IsValidSessionID. The name is retained for older call sites
// while party-* IDs are phased out.
func IsValidPartyID(id string) bool {
	return IsValidSessionID(id)
}

// HasSessionIDPrefix reports whether id starts with a supported session prefix,
// without validating the full ID shape.
func HasSessionIDPrefix(id string) bool {
	return strings.HasPrefix(id, SessionIDPrefix) || strings.HasPrefix(id, LegacySessionIDPrefix)
}

// TrimSessionIDPrefix removes a supported session prefix when present.
func TrimSessionIDPrefix(id string) string {
	switch {
	case strings.HasPrefix(id, SessionIDPrefix):
		return strings.TrimPrefix(id, SessionIDPrefix)
	case strings.HasPrefix(id, LegacySessionIDPrefix):
		return strings.TrimPrefix(id, LegacySessionIDPrefix)
	default:
		return id
	}
}

// SessionIDFromEnv returns the current session ID from the preferred
// QUESTMASTER_SESSION env var, falling back to legacy PARTY_SESSION.
func SessionIDFromEnv() string {
	if id := os.Getenv(SessionEnv); id != "" {
		return id
	}
	return os.Getenv(LegacySessionEnv)
}
