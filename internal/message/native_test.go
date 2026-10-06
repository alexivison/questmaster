//go:build linux || darwin

package message

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestClaudeNativeWritesFrameWithoutTmux(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-claude-native", "claude", "worker")
	configDir, err := os.MkdirTemp("/tmp", "qm-claude-native-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(configDir) })
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := os.Mkdir(sessionsDir, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(configDir, "inbox.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := os.Chmod(listener.Addr().String(), 0o600); err != nil {
		t.Fatal(err)
	}
	pid := os.Getpid()
	canonical := "qm-claude-native:@0.%1"
	record, _ := json.Marshal(claudeSessionRecord{PID: pid, PeerProtocol: 1, Tmux: canonical, MessagingSocketPath: listener.Addr().String()})
	if err := os.WriteFile(filepath.Join(sessionsDir, strconv.Itoa(pid)+".json"), record, 0o600); err != nil {
		t.Fatal(err)
	}
	var sent []string
	base := idleAndSendRunner(&sent)
	runner := &mockRunner{fn: func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "display-message" {
			return strconv.Itoa(pid) + "\t" + canonical, nil
		}
		return base.Run(ctx, args...)
	}}
	svc := newService(store, runner)
	received := make(chan claudeMessageFrame, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		line, err := bufio.NewReader(conn).ReadBytes('\n')
		if err != nil {
			return
		}
		var frame claudeMessageFrame
		if json.Unmarshal(line, &frame) == nil {
			received <- frame
		}
	}()
	if err := svc.Relay(t.Context(), "qm-claude-native", "hello"); err != nil {
		t.Fatal(err)
	}
	select {
	case frame := <-received:
		if frame.Message.Content != "<cross-session-message from-name=\"Questmaster\">\n[FROM:external] hello\n</cross-session-message>" || len(sent) != 0 {
			t.Fatalf("frame = %+v, tmux = %v", frame, sent)
		}
	case <-time.After(time.Second):
		t.Fatal("Claude did not receive frame")
	}
}

func TestClaudeInboundProjectRestriction(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "sub")
	if err := os.MkdirAll(filepath.Join(root, ".claude"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(child, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, value := range []string{"hold", "refuse"} {
		if err := os.WriteFile(filepath.Join(root, ".claude", "settings.json"), []byte(`{"crossSessionInbound":"`+value+`"}`), 0o600); err != nil {
			t.Fatal(err)
		}
		restricted, err := claudeInboundRestricted(child)
		if err != nil || !restricted {
			t.Fatalf("%s restriction = %v, %v", value, restricted, err)
		}
	}
	store := setupStore(t)
	createManifest(t, store, "qm-restricted-claude", "claude", "worker")
	if err := store.Update("qm-restricted-claude", func(m *state.Manifest) { m.Cwd = child }); err != nil {
		t.Fatal(err)
	}
	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	if err := svc.Relay(t.Context(), "qm-restricted-claude", "hello"); err != nil {
		t.Fatal(err)
	}
	if len(sent) != 1 || sent[0] != "[FROM:external] hello" {
		t.Fatalf("restricted Claude tmux fallback = %v", sent)
	}
}

func TestClaudeUndecidableSettingsUseTmux(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(string) error
	}{
		{"malformed", func(path string) error { return os.WriteFile(path, []byte(`{"crossSessionInbound":`), 0o600) }},
		{"unreadable", func(path string) error { return os.Mkdir(path, 0o700) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cwd := t.TempDir()
			if err := os.Mkdir(filepath.Join(cwd, ".claude"), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := tc.setup(filepath.Join(cwd, ".claude", "settings.json")); err != nil {
				t.Fatal(err)
			}
			store := setupStore(t)
			createManifest(t, store, "qm-claude-settings", "claude", "worker")
			if err := store.Update("qm-claude-settings", func(m *state.Manifest) { m.Cwd = cwd }); err != nil {
				t.Fatal(err)
			}
			var sent []string
			svc := newService(store, idleAndSendRunner(&sent))
			if err := svc.Relay(t.Context(), "qm-claude-settings", "hello"); err != nil {
				t.Fatal(err)
			}
			if len(sent) != 1 || sent[0] != "[FROM:external] hello" {
				t.Fatalf("Claude tmux fallback = %v", sent)
			}
		})
	}
}

func TestPiReceiptIsUnconfirmedAndNeverRetried(t *testing.T) {
	runtime, err := os.MkdirTemp("/tmp", "qm-native-pi-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(runtime) })
	if err := os.Chmod(runtime, 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(runtime, "pi.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	store := setupStore(t)
	id := filepath.Base(runtime)
	createManifest(t, store, id, "pi", "worker")
	setPrimaryAgent(t, store, id, "pi")
	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	got := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request piMessageRequest
		_ = json.NewDecoder(conn).Decode(&request)
		got <- request.Message
		_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"unconfirmed"}` + "\n"))
	}()
	message := strings.Repeat("x", LargeMessageThreshold+1)
	if err := svc.Relay(t.Context(), id, message); err != nil {
		t.Fatal(err)
	}
	if <-got != "[FROM:external] "+message || len(sent) != 0 {
		t.Fatalf("Pi native message or tmux fallback wrong: %v", sent)
	}
	svc.dial = func(context.Context, string, string) (net.Conn, error) {
		return &failingConn{}, nil
	}
	if err := svc.Relay(t.Context(), id, "again"); err == nil || errors.Is(err, errNativeUnavailable) {
		t.Fatalf("post-connect error = %v", err)
	}
	if len(sent) != 0 {
		t.Fatalf("post-connect Pi failure retried: %v", sent)
	}
}

type failingConn struct{ net.Conn }

func (f *failingConn) Write([]byte) (int, error)   { return 1, errors.New("write failed") }
func (f *failingConn) SetDeadline(time.Time) error { return nil }
func (f *failingConn) Close() error                { return nil }
