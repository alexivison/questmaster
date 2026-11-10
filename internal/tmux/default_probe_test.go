package tmux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

type defaultProbeRunner func(context.Context, ...string) (string, error)

func (f defaultProbeRunner) Run(ctx context.Context, args ...string) (string, error) {
	return f(ctx, args...)
}

func TestDefaultProbeOnlyListsSessions(t *testing.T) {
	for _, tc := range []struct {
		name, output string
		err          error
		present      bool
		wantErr      bool
	}{
		{name: "plain shell", output: "shell-example", present: true},
		{name: "missing socket", err: &ExitError{Code: 1, Stderr: "error connecting to /tmp/example (No such file or directory)"}},
		{name: "no server", err: &ExitError{Code: 1, Stderr: "no server running"}},
		{name: "permission denied", err: &ExitError{Code: 1, Stderr: "Permission denied"}, wantErr: true},
		{name: "timeout", err: context.DeadlineExceeded, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			ids, present, err := probeDefaultSessions(t.Context(), defaultProbeRunner(func(_ context.Context, args ...string) (string, error) {
				calls++
				if !slices.Equal(args, []string{"list-sessions", "-F", "#{session_name}"}) {
					t.Fatalf("probe command=%v", args)
				}
				return tc.output, tc.err
			}))
			if calls != 1 || present != tc.present || (err != nil) != tc.wantErr {
				t.Fatalf("ids=%v present=%v calls=%d err=%v", ids, present, calls, err)
			}
		})
	}
}

func TestDefaultSocketPathFollowsTmuxDirectory(t *testing.T) {
	t.Setenv("TMUX", "/tmp/unrelated/socket,1,0")
	t.Setenv("TMUX_TMPDIR", t.TempDir())
	want := filepath.Join(os.Getenv("TMUX_TMPDIR"), fmt.Sprintf("tmux-%d", os.Getuid()), "default")
	if got, err := defaultSocketPath(); err != nil || got != want {
		t.Fatalf("socket=%q want=%q", got, want)
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(cwd, os.Getenv("TMUX_TMPDIR"))
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", relative)
	if got, err := defaultSocketPath(); err != nil || got != want {
		t.Fatalf("relative socket=%q want=%q", got, want)
	}
	t.Setenv("TMUX_TMPDIR", "")
	want = filepath.Join("/tmp", fmt.Sprintf("tmux-%d", os.Getuid()), "default")
	if got, err := defaultSocketPath(); err != nil || got != want {
		t.Fatalf("socket=%q want=%q", got, want)
	}
}
