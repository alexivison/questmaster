//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
)

func transportRunner(sessionID, currentRole string) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) == 0 {
			return "", fmt.Errorf("missing tmux args")
		}
		switch args[0] {
		case "display-message":
			format := args[len(args)-1]
			switch format {
			case "#{session_name}":
				return sessionID, nil
			case "#{session_name}\t#{window_index}\t#{pane_index}\t#{@party_role}":
				return fmt.Sprintf("%s\t1\t0\t%s", sessionID, currentRole), nil
			case "#{pane_in_mode}":
				return "0", nil
			default:
				return "", fmt.Errorf("unexpected display-message format %q", format)
			}
		case "list-panes":
			return "0 0 companion\n1 0 primary", nil
		case "send-keys":
			return "", nil
		default:
			return "", fmt.Errorf("unexpected tmux command: %v", args)
		}
	}}
}

func TestTransportCmd_MissingArgs(t *testing.T) {
	store := setupStore(t)
	t.Setenv("PARTY_SESSION", "")

	_, err := runCmdErr(t, store, transportRunner("party-cmd", tmux.RolePrimary), "transport")
	if err == nil {
		t.Fatal("expected missing arg error")
	}
}

func TestTransportCmd_UsesDiscoverSession(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-cmd", "worker", "/tmp", "worker")
	t.Setenv("PARTY_SESSION", "")

	out := runCmd(t, store, transportRunner("party-cmd", tmux.RolePrimary), "transport", "hello")
	if !strings.Contains(out, "Delivered to companion in party-cmd") {
		t.Fatalf("unexpected output: %q", out)
	}
}

func TestTransportCmd_MasterWritesCompatErrorToStderr(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "/tmp", "master")
	t.Setenv("PARTY_SESSION", "party-master")

	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
		WithDeps(store, tmux.NewClient(transportRunner("party-master", tmux.RolePrimary))),
	)
	var stdout, stderr bytes.Buffer
	root.SetOut(&stdout)
	root.SetErr(&stderr)
	root.SetArgs([]string{"transport", "hello"})

	err := root.Execute()
	if err == nil {
		t.Fatal("expected master session error")
	}
	if !IsSilentError(err) {
		t.Fatalf("expected silent error wrapper, got %T", err)
	}
	if got := strings.TrimSpace(stderr.String()); got != "COMPANION_NOT_AVAILABLE: Master sessions have no companion pane." {
		t.Fatalf("stderr: got %q", got)
	}
}
