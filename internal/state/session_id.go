package state

import (
	"fmt"
	"os"
	"regexp"
	"strings"
)

const (
	// SessionIDPrefix is used for all questmaster session IDs.
	SessionIDPrefix = "qm-"

	// SessionEnv is the environment variable for the current session ID.
	SessionEnv = "QUESTMASTER_SESSION"

	// StateRootEnv is the environment variable for the state root.
	StateRootEnv = "QUESTMASTER_STATE_ROOT"
)

var validSessionID = regexp.MustCompile(`^qm-[A-Za-z0-9_-]+$`)

// NewSessionID formats the base ID for a new questmaster session.
func NewSessionID(timestamp int64) string {
	return fmt.Sprintf("%s%d", SessionIDPrefix, timestamp)
}

// NewSessionIDWithSuffix formats a collision-retry ID for a new questmaster session.
func NewSessionIDWithSuffix(timestamp, suffix int64) string {
	return fmt.Sprintf("%s%d-%d", SessionIDPrefix, timestamp, suffix)
}

// IsValidSessionID reports whether id is a supported questmaster session ID.
func IsValidSessionID(id string) bool {
	return validSessionID.MatchString(id)
}

// HasSessionIDPrefix reports whether id starts with the session prefix,
// without validating the full ID shape.
func HasSessionIDPrefix(id string) bool {
	return strings.HasPrefix(id, SessionIDPrefix)
}

// TrimSessionIDPrefix removes the session prefix when present.
func TrimSessionIDPrefix(id string) string {
	return strings.TrimPrefix(id, SessionIDPrefix)
}

// SessionIDFromEnv returns the current session ID from QUESTMASTER_SESSION.
func SessionIDFromEnv() string {
	return os.Getenv(SessionEnv)
}
