package picker

import (
	"reflect"
	"testing"
)

func TestZoxideQueryArgsTerminateFlagsBeforeFragmentTerms(t *testing.T) {
	got := zoxideQueryArgs("-sensitive repo")
	want := []string{"query", "-l", "--", "-sensitive", "repo"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("zoxide args = %v, want %v", got, want)
	}
}
