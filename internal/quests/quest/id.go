package quest

import "fmt"

const IDPrefix = "quest-"

// NewID formats the base ID for an auto-generated quest.
func NewID(timestamp int64) string {
	return fmt.Sprintf("%s%d", IDPrefix, timestamp)
}

// NewIDWithSuffix formats a collision-retry ID for an auto-generated quest.
func NewIDWithSuffix(timestamp int64, suffix int) string {
	return fmt.Sprintf("%s%d-%d", IDPrefix, timestamp, suffix)
}
