package focus

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseDirection(t *testing.T) {
	t.Parallel()

	tests := map[string]Direction{
		"h":     Left,
		"left":  Left,
		"j":     Down,
		"down":  Down,
		"k":     Up,
		"up":    Up,
		"l":     Right,
		"right": Right,
	}
	for input, want := range tests {
		got, err := ParseDirection(input)
		if err != nil {
			t.Fatalf("ParseDirection(%q): %v", input, err)
		}
		if got != want {
			t.Fatalf("ParseDirection(%q) = %q, want %q", input, got, want)
		}
	}

	if _, err := ParseDirection("north"); err == nil {
		t.Fatal("ParseDirection accepted an invalid direction")
	}
}

func TestDefaultSocketPathHonorsEnv(t *testing.T) {
	t.Setenv(SocketEnv, filepath.Join(t.TempDir(), "focus.sock"))

	if got, want := DefaultSocketPath(), os.Getenv(SocketEnv); got != want {
		t.Fatalf("DefaultSocketPath() = %q, want %q", got, want)
	}
}

func TestSendWritesDirectionAndWaitsForAck(t *testing.T) {
	t.Parallel()

	socketDir, err := os.MkdirTemp("/tmp", "qm-focus-test-")
	if err != nil {
		t.Fatalf("temp dir: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(socketDir) }) //nolint:errcheck
	socketPath := filepath.Join(socketDir, "focus.sock")
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close() //nolint:errcheck

	got := make(chan Direction, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close() //nolint:errcheck

		var req request
		if err := json.NewDecoder(conn).Decode(&req); err != nil {
			return
		}
		got <- req.Direction
		_ = json.NewEncoder(conn).Encode(response{OK: true})
	}()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := Send(ctx, socketPath, Right); err != nil {
		t.Fatalf("Send: %v", err)
	}

	select {
	case direction := <-got:
		if direction != Right {
			t.Fatalf("direction = %q, want %q", direction, Right)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for focus request")
	}
}
