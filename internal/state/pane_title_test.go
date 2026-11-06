package state

import (
	"context"
	"errors"
	"slices"
	"testing"
)

// titleSequence returns one manifest per Read, as if renames committed
// between pane writes.
type titleSequence struct{ reads []Manifest }

func (s *titleSequence) Read(string) (Manifest, error) {
	m := s.reads[0]
	if len(s.reads) > 1 {
		s.reads = s.reads[1:]
	}
	return m, nil
}

type recordedPaneTitles []string

func (r *recordedPaneTitles) SetManagedPaneTitle(_ context.Context, _ string, title string) error {
	*r = append(*r, title)
	return nil
}

func agentManifest(title string) Manifest {
	return Manifest{Title: title, Agents: []AgentManifest{{Name: "claude", Role: "agent"}}}
}

func TestWriteCommittedPaneTitleFollowsTitlesCommittedDuringTheWrite(t *testing.T) {
	for _, tc := range []struct {
		name    string
		reads   []Manifest
		want    []string
		wantErr bool
	}{
		{"unchanged", []Manifest{agentManifest("Derived")}, []string{"Derived"}, false},
		{"renamed during the write", []Manifest{agentManifest("Explicit"), agentManifest("Explicit")}, []string{"Derived", "Explicit"}, false},
		{"renamed twice", []Manifest{agentManifest("First"), agentManifest("Second"), agentManifest("Second")}, []string{"Derived", "First", "Second"}, false},
		{"agent left", []Manifest{{Title: "Shell"}}, []string{"Derived"}, false},
		{"title never settles", []Manifest{agentManifest("A"), agentManifest("B"), agentManifest("C")}, []string{"Derived", "A", "B"}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var panes recordedPaneTitles
			err := WriteCommittedPaneTitle(t.Context(), &titleSequence{reads: tc.reads}, &panes, "qm-title", "=qm-title:0.0", "Derived")
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v, want error %v", err, tc.wantErr)
			}
			if !slices.Equal(panes, tc.want) {
				t.Fatalf("pane writes = %q, want %q", panes, tc.want)
			}
		})
	}
}

type failingPaneTitles struct{}

func (failingPaneTitles) SetManagedPaneTitle(context.Context, string, string) error {
	return errors.New("tmux unreachable")
}

func TestWriteCommittedPaneTitleReturnsTheTmuxError(t *testing.T) {
	err := WriteCommittedPaneTitle(t.Context(), &titleSequence{reads: []Manifest{agentManifest("Derived")}}, failingPaneTitles{}, "qm-title", "=qm-title:0.0", "Derived")
	if err == nil || err.Error() != "tmux unreachable" {
		t.Fatalf("err = %v, want the tmux error", err)
	}
}
