//go:build linux || darwin

package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestEnsureLifetimeLockWaitHonorsDeadline(t *testing.T) {
	t.Parallel()
	root, home := t.TempDir(), t.TempDir()
	executable := filepath.Join(t.TempDir(), "qm")
	if err := os.WriteFile(executable, []byte("test binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(executable, link); err != nil {
		t.Fatal(err)
	}
	lockPath := filepath.Join(root, "daemon", "canonical.lock")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)

	waited := make(chan struct{}, 1)
	config := Config{
		Root:               root,
		Home:               home,
		Executable:         link,
		PollInterval:       time.Millisecond,
		OnLifetimeLockWait: func() { waited <- struct{}{} },
	}
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	startedAt := time.Now()
	_, err = Ensure(ctx, config)
	if err == nil || !strings.Contains(err.Error(), "wait for daemon lifetime lock holder") {
		t.Fatalf("Ensure error = %v, want bounded lifetime-lock wait error", err)
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Ensure error = %v, want context deadline exceeded", err)
	}
	if time.Since(startedAt) > time.Second {
		t.Fatalf("Ensure exceeded its deadline by too much: %v", time.Since(startedAt))
	}
	select {
	case <-waited:
	default:
		t.Fatal("Ensure did not report waiting for the held lifetime lock")
	}
}
