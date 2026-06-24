//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestFocusCommandSendsDirection(t *testing.T) {
	t.Parallel()

	socketDir, err := os.MkdirTemp("/tmp", "qm-focus-cmd-")
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

	got := make(chan string, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close() //nolint:errcheck

		var req struct {
			Direction string `json:"direction"`
		}
		if err := json.NewDecoder(conn).Decode(&req); err != nil {
			return
		}
		got <- req.Direction
		_ = json.NewEncoder(conn).Encode(map[string]bool{"ok": true})
	}()

	runCmd(t, setupStore(t), sessionsRunner(), "focus", "l", "--socket", socketPath)

	select {
	case direction := <-got:
		if direction != "right" {
			t.Fatalf("direction = %q, want right", direction)
		}
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for focus request")
	}
}
