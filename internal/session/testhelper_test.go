//go:build linux || darwin

package session

import "context"

// testRunner is a mock tmux.Runner for session package tests.
type testRunner struct {
	fn    func(ctx context.Context, args ...string) (string, error)
	calls [][]string
}

func (r *testRunner) Run(ctx context.Context, args ...string) (string, error) {
	copied := make([]string, len(args))
	copy(copied, args)
	r.calls = append(r.calls, copied)
	return r.fn(ctx, args...)
}
