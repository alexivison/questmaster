//go:build darwin

package cmd

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
)

func TestDaemonStartMigratesLegacyShimsToStableLinkForOldRecord(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "qm")
	copyDaemonBinary(t, cachedDaemonCLI.binary(t, ".."), bin)
	home, root := t.TempDir(), t.TempDir()
	localBin := filepath.Join(home, ".local", "bin")
	if err := os.MkdirAll(localBin, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(bin, filepath.Join(localBin, "questmaster")); err != nil {
		t.Fatal(err)
	}
	stable := daemon.StableExecutable(root)
	if err := os.MkdirAll(filepath.Dir(stable), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(bin, stable); err != nil {
		t.Fatal(err)
	}

	legacyBin := filepath.Join(home, "Library", "Application Support", "Questmaster", "0123456789abcdef", "bin")
	if err := os.MkdirAll(legacyBin, 0o700); err != nil {
		t.Fatal(err)
	}
	oldShim := "#!/bin/sh\nexec '/old/qm' \"$@\"\n"
	for _, name := range []string{"qm", "questmaster"} {
		if err := os.WriteFile(filepath.Join(legacyBin, name), []byte(oldShim), 0o700); err != nil {
			t.Fatal(err)
		}
	}

	daemonDir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(daemonDir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket, err := daemon.SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	oldExecutable := filepath.Join(root, "bin", "versions", "old-build", "qm")
	data, err := json.Marshal(daemon.Record{
		Running: true, PID: 123, Root: root, Identity: "canonical", Socket: socket,
		Executable: oldExecutable, Build: "old-build", Generation: 1, Accepting: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	serveDone := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			serveDone <- err
			return
		}
		defer conn.Close()
		encoder := json.NewEncoder(conn)
		if err := encoder.Encode(map[string]any{
			"root": root, "identity": "canonical", "protocol_version": daemon.ProtocolVersion,
			"generation": 1, "accepting": true,
		}); err != nil {
			serveDone <- err
			return
		}
		var request struct {
			Method string `json:"method"`
		}
		if err := json.NewDecoder(conn).Decode(&request); err != nil {
			serveDone <- err
			return
		}
		if request.Method != "status" {
			serveDone <- errors.New("expected status request, got " + request.Method)
			return
		}
		if err := encoder.Encode(struct {
			OK   bool            `json:"ok"`
			Data json.RawMessage `json:"data"`
		}{OK: true, Data: data}); err != nil {
			serveDone <- err
			return
		}
		serveDone <- nil
	}()

	h := &daemonHarness{
		t: t, bin: bin, home: home, root: root,
		env: append(os.Environ(), "HOME="+home, "QUESTMASTER_STATE_ROOT="+root),
	}
	if _, err := h.command("daemon", "start"); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-serveDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("fake daemon did not answer status")
	}
	want := "#!/bin/sh\nexec '" + stable + "' \"$@\"\n"
	for _, name := range []string{"qm", "questmaster"} {
		got, err := os.ReadFile(filepath.Join(legacyBin, name))
		if err != nil || string(got) != want {
			t.Fatalf("migrated %s shim = %q (%v), want stable link %q instead of stale record path %q", name, got, err, stable, oldExecutable)
		}
	}
}
