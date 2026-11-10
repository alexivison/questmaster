package tmux

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
)

// defaultSocketPath follows tmux's socket directory rule, independently of TMUX.
func defaultSocketPath() (string, error) {
	base := os.Getenv("TMUX_TMPDIR")
	if base == "" {
		base = "/tmp"
	}
	// Server commands run from /, so resolve a relative override here.
	return filepath.Abs(filepath.Join(base, fmt.Sprintf("tmux-%d", os.Getuid()), "default"))
}

// ProbeDefaultSessions is the only production reader of the user's default
// server. Audit and stopped-manifest backfill need proof that no managed
// session remains there; no caller receives a client capable of mutations.
func ProbeDefaultSessions(ctx context.Context) ([]string, bool, error) {
	socket, err := defaultSocketPath()
	if err != nil {
		return nil, false, fmt.Errorf("resolve default tmux socket: %w", err)
	}
	return probeDefaultSessions(ctx, SocketServer(socket))
}

func probeDefaultSessions(ctx context.Context, runner Runner) ([]string, bool, error) {
	return NewClient(runner).ListSessionsStatus(ctx)
}
