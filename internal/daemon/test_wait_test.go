//go:build linux || darwin

package daemon

import (
	"testing"
	"time"
)

const daemonTestWaitTimeout = 10 * time.Second

func receiveDaemonTestValue[T any](t *testing.T, ch <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(daemonTestWaitTimeout):
		t.Fatalf("timed out after %s waiting for %s", daemonTestWaitTimeout, description)
		var zero T
		return zero
	}
}
