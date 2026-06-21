package mergeback

import (
	"strings"
	"testing"
)

func TestParseMergeTreeConflictOutputRejectsHardErrors(t *testing.T) {
	out := "fatal: refusing to merge unrelated histories\nhint: use --allow-unrelated-histories if you want to merge anyway\n"
	conflicts, ok := parseMergeTreeConflictOutput(out)
	if ok {
		t.Fatalf("hard merge-tree error parsed as conflict: ok=%v conflicts=%v", ok, conflicts)
	}
	if len(conflicts) != 0 {
		t.Fatalf("hard merge-tree error conflicts = %v, want none", conflicts)
	}
}

func TestParseMergeTreeConflictOutputRequiresTreeSHA(t *testing.T) {
	sha := strings.Repeat("a", 40)
	conflicts, ok := parseMergeTreeConflictOutput(sha + "\ninternal/file.go\n\nAuto-merging internal/file.go\n")
	if !ok {
		t.Fatal("valid merge-tree conflict output was not recognized")
	}
	if len(conflicts) != 1 || conflicts[0] != "internal/file.go" {
		t.Fatalf("conflicts = %v, want [internal/file.go]", conflicts)
	}
}
