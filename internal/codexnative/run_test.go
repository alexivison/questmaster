package codexnative

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestRunOwnsServerLifetime(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{"tui-exits", "server-exits", "cancel"} {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			dir := runtimeFixture(t)
			ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
			defer cancel()
			command := func(_ string, args ...string) *exec.Cmd {
				cmd := exec.Command(os.Args[0], append([]string{"-test.run=^TestCodexLauncherHelper$", "--"}, args...)...)
				cmd.Env = append(os.Environ(), "QM_CODEX_HELPER=1", "QM_CODEX_HELPER_DIR="+dir, "QM_CODEX_HELPER_MODE="+mode, "QUESTMASTER_SESSION=example-worker")
				return cmd
			}
			if mode == "cancel" {
				go func() {
					ticker := time.NewTicker(10 * time.Millisecond)
					defer ticker.Stop()
					for {
						select {
						case <-ctx.Done():
							return
						case <-ticker.C:
							if _, err := os.Stat(filepath.Join(dir, "tui.json")); err == nil {
								cancel()
								return
							}
						}
					}
				}()
			}
			err := Run(ctx, Options{Binary: "example-codex", RuntimeDir: dir, Config: []string{`model="example-model"`}, Args: []string{"resume", "example-thread"}, In: strings.NewReader(""), Out: io.Discard, Err: io.Discard, command: command})
			if mode == "tui-exits" && err != nil {
				t.Fatal(err)
			}
			if mode != "tui-exits" && err == nil {
				t.Fatal("unexpected success")
			}
			if _, err := os.Stat(filepath.Join(dir, SocketName)); !os.IsNotExist(err) {
				t.Fatalf("socket retained: %v", err)
			}
			if _, err := os.Stat(filepath.Join(dir, "server-stopped")); err != nil {
				t.Fatalf("server not reaped: %v", err)
			}
			data, err := os.ReadFile(filepath.Join(dir, "tui.json"))
			if err != nil {
				t.Fatal(err)
			}
			if !strings.Contains(string(data), "--remote") || !strings.Contains(string(data), "example-worker") || !strings.Contains(string(data), "example-model") {
				t.Fatalf("TUI context = %s", data)
			}
		})
	}
}

func TestCodexLauncherHelper(t *testing.T) {
	if os.Getenv("QM_CODEX_HELPER") != "1" {
		return
	}
	dir, mode := os.Getenv("QM_CODEX_HELPER_DIR"), os.Getenv("QM_CODEX_HELPER_MODE")
	args := os.Args
	if strings.Contains(strings.Join(args, " "), "app-server --listen") {
		// Publish readiness only after termination handling and the private
		// socket umask are in place, as Codex's guarded rendezvous does.
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM)
		syscall.Umask(0o077)
		listener, err := net.Listen("unix", filepath.Join(dir, SocketName))
		if err != nil {
			os.Exit(2)
		}
		if err := os.Chmod(filepath.Join(dir, SocketName), 0o600); err != nil {
			os.Exit(6)
		}
		defer listener.Close()
		conn, err := listener.Accept()
		if err != nil {
			os.Exit(3)
		}
		conn.Close()
		if mode == "server-exits" {
			// Let the TUI start before ending its owner.
			deadline := time.NewTimer(3 * time.Second)
			defer deadline.Stop()
			ticker := time.NewTicker(10 * time.Millisecond)
			defer ticker.Stop()
			for {
				if _, err := os.Stat(filepath.Join(dir, "tui.json")); err == nil {
					break
				}
				select {
				case <-ticker.C:
				case <-deadline.C:
					os.Exit(4)
				}
			}
		} else {
			<-signals
		}
		_ = os.WriteFile(filepath.Join(dir, "server-stopped"), []byte("yes"), 0o600)
		return
	}
	data, _ := json.Marshal(map[string]any{"args": args, "worker": os.Getenv("QUESTMASTER_SESSION")})
	if err := os.WriteFile(filepath.Join(dir, "tui.json"), data, 0o600); err != nil {
		os.Exit(5)
	}
	if mode != "tui-exits" {
		signals := make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM)
		<-signals
	}
}
