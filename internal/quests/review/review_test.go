package review

import (
	"testing"
)

func TestResolveViewerPrecedence(t *testing.T) {
	t.Setenv(ViewerEnv, "")
	if got := ResolveViewer(""); got != DefaultViewer {
		t.Errorf("default viewer = %q, want %q", got, DefaultViewer)
	}

	t.Setenv(ViewerEnv, "delta")
	if got := ResolveViewer(""); got != "delta" {
		t.Errorf("env viewer = %q, want delta", got)
	}
	if got := ResolveViewer("difftastic"); got != "difftastic" {
		t.Errorf("flag viewer = %q, want difftastic (flag wins)", got)
	}
}

func TestCommandViewerBuildsCommand(t *testing.T) {
	var gotBin string
	var gotArgs []string
	v := &CommandViewer{
		Bin: "scry",
		Run: func(bin string, args ...string) error {
			gotBin = bin
			gotArgs = args
			return nil
		},
	}
	if err := v.Open("webapp/.wt/eng-142", "main"); err != nil {
		t.Fatalf("Open: %v", err)
	}
	if gotBin != "scry" {
		t.Errorf("bin = %q, want scry", gotBin)
	}
	want := []string{"--base", "main", "webapp/.wt/eng-142"}
	if len(gotArgs) != len(want) {
		t.Fatalf("args = %v, want %v", gotArgs, want)
	}
	for i := range want {
		if gotArgs[i] != want[i] {
			t.Errorf("arg[%d] = %q, want %q", i, gotArgs[i], want[i])
		}
	}
}
