package picker

import (
	"reflect"
	"testing"
)

func TestFuzzyRankEmptyQueryPreservesOrder(t *testing.T) {
	in := []string{"/a/b", "/c/d", "/e/f"}
	got := fuzzyRank("", in)
	if !reflect.DeepEqual(got, in) {
		t.Fatalf("empty query reordered: got %v", got)
	}
}

func TestFuzzyRankFiltersNonMatches(t *testing.T) {
	in := []string{"/home/user/questmaster", "/tmp/scratch", "/home/user/quotes"}
	got := fuzzyRank("qm", in)
	for _, g := range got {
		if g == "/tmp/scratch" {
			t.Fatalf("non-match %q survived filtering: %v", g, got)
		}
	}
	if len(got) == 0 {
		t.Fatal("expected at least one match for 'qm'")
	}
}

func TestFuzzyRankSubsequenceOrderMatters(t *testing.T) {
	in := []string{"/home/abc", "/home/cba"}
	got := fuzzyRank("abc", in)
	if len(got) != 1 || got[0] != "/home/abc" {
		t.Fatalf("abc should match only /home/abc, got %v", got)
	}
}

func TestFuzzyRankPrefersWordBoundary(t *testing.T) {
	// "qm" should rank the boundary-aligned ".../questmaster" ahead of a
	// path where q and m are buried mid-word.
	in := []string{"/home/aqxmy/inner", "/home/user/questmaster"}
	got := fuzzyRank("qm", in)
	if len(got) == 0 || got[0] != "/home/user/questmaster" {
		t.Fatalf("expected questmaster ranked first, got %v", got)
	}
}

func TestFuzzyRankCaseInsensitive(t *testing.T) {
	in := []string{"/Home/User/QuestMaster"}
	got := fuzzyRank("questmaster", in)
	if len(got) != 1 {
		t.Fatalf("case-insensitive match failed: %v", got)
	}
}
