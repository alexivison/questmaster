package serve

import (
	"testing"
	"time"
)

const serveTestWaitTimeout = 10 * time.Second

func receiveServeTestValue[T any](t *testing.T, ch <-chan T, description string) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(serveTestWaitTimeout):
		t.Fatalf("timed out after %s waiting for %s", serveTestWaitTimeout, description)
		var zero T
		return zero
	}
}
