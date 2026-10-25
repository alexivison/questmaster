//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestEnsureNudgesOlderProtocolBeforeSpawning(t *testing.T) {
	t.Parallel()
	root, home := t.TempDir(), t.TempDir()
	binary := filepath.Join(t.TempDir(), "qm")
	if err := os.WriteFile(binary, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(binary, link); err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var upgraded atomic.Bool
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				version := 1
				if upgraded.Load() {
					version = ProtocolVersion
				}
				_ = json.NewEncoder(conn).Encode(hello{Root: root, Identity: "canonical", ProtocolVersion: version, Accepting: true})
				var req request
				if json.NewDecoder(conn).Decode(&req) != nil {
					return
				}
				if req.Method == "check-upgrade" {
					_ = json.NewEncoder(conn).Encode(map[string]any{"ok": true, "data": Record{Running: true, UpgradeStarted: true}})
					upgraded.Store(true)
					return
				}
				_ = json.NewEncoder(conn).Encode(map[string]any{"ok": true, "data": Record{Running: true, Root: root, Identity: "canonical", Socket: socket}})
			}()
		}
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	record, err := Ensure(ctx, Config{Root: root, Home: home, Executable: binary, PollInterval: 10 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	if !upgraded.Load() || !record.Running || record.Identity != "canonical" {
		t.Fatalf("upgrade handoff: %+v", record)
	}
	listener.Close()
	<-done
}
