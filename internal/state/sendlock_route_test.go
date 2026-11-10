package state_test

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type sendPaneRunner struct{}

func (sendPaneRunner) Run(_ context.Context, args ...string) (string, error) {
	if args[0] == "display-message" {
		if args[len(args)-1] == "#{pane_id}\t#{pane_dead}" {
			return "%0\t0", nil
		}
		return "0", nil
	}
	return "", nil
}

func TestSendLocksNamespacedPerServer(t *testing.T) {
	root := t.TempDir()
	legacy := state.SendLockDirForServer(root, "dev_previous")
	named := state.SendLockDirForServer(root, "questmaster")
	if legacy != filepath.Join(state.SendLockDir(root), "dev_previous") || named != filepath.Join(state.SendLockDir(root), "questmaster") {
		t.Fatalf("lock dirs: legacy=%q named=%q", legacy, named)
	}
	if err := os.MkdirAll(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(filepath.Join(legacy, "pane-0.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
	client := tmux.NewClient(sendPaneRunner{})
	if result := client.Send(t.Context(), named, "=qm-example:", "hello"); !result.Submitted {
		t.Fatalf("named send blocked by legacy lock: %v", result.Err)
	}
}
