//go:build linux || darwin

package session

import (
	"testing"
	"time"
)

const sessionTestWaitTimeout = 10 * time.Second

func receiveSessionTestValue[T any](t *testing.T, ch <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(sessionTestWaitTimeout):
		t.Fatalf("timed out after %s waiting for %s", sessionTestWaitTimeout, description)
		var zero T
		return zero
	}
}
