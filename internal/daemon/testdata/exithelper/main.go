//go:build linux || darwin

package main

import (
	"context"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
)

type drainJob struct{ root string }

func (j drainJob) Name() string { return "drain" }
func (j drainJob) HasWork() bool {
	_, err := os.Stat(filepath.Join(j.root, "daemon", "work"))
	return err == nil
}
func (j drainJob) Run(ctx context.Context) error {
	<-ctx.Done()
	_ = os.WriteFile(filepath.Join(j.root, "daemon", "draining"), nil, 0o600)
	for {
		if _, err := os.Stat(filepath.Join(j.root, "daemon", "release-drain")); err == nil {
			return nil
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	root := os.Getenv("QUESTMASTER_STATE_ROOT")
	if err := daemon.Run(ctx, daemon.Config{Root: root, Home: os.Getenv("HOME"), IdleGrace: 500 * time.Millisecond, PollInterval: 10 * time.Millisecond, Jobs: []daemon.Job{drainJob{root}}}, false); err != nil {
		os.Exit(1)
	}
}
