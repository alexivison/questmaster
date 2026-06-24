package textutil

import "strings"

const boundedOutputMaxRunes = 2000

func BoundedOutput(message string) string {
	runes := []rune(strings.TrimSpace(message))
	if len(runes) <= boundedOutputMaxRunes {
		return string(runes)
	}
	return string(runes[:boundedOutputMaxRunes]) + "\n[... output truncated ...]"
}
