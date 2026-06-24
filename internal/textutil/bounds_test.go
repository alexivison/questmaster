package textutil

import (
	"strings"
	"testing"
)

func TestBoundedOutputTrimsAndCapsRunes(t *testing.T) {
	if got := BoundedOutput("  short  "); got != "short" {
		t.Fatalf("BoundedOutput trim = %q, want short", got)
	}
	long := strings.Repeat("x", boundedOutputMaxRunes+1)
	got := BoundedOutput(long)
	if !strings.HasSuffix(got, "\n[... output truncated ...]") {
		t.Fatalf("BoundedOutput missing truncation marker")
	}
	if strings.Count(got, "x") != boundedOutputMaxRunes {
		t.Fatalf("BoundedOutput kept %d x runes, want %d", strings.Count(got, "x"), boundedOutputMaxRunes)
	}
}
