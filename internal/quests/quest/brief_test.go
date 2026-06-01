package quest

import (
	"strings"
	"testing"
)

func TestSystemBriefMentionsEssentials(t *testing.T) {
	b := SystemBrief()
	for _, want := range []string{"quest-head", "quests quest new", "quests quest edit", "auto", "toggle", "~/.quests"} {
		if !strings.Contains(b, want) {
			t.Errorf("SystemBrief missing %q", want)
		}
	}
}
