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
	"github.com/alexivison/questmaster/internal/tmux"
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
		if frame.Message.Content != "<cross-session-message from-name=\"Questmaster\">\nhello\n</cross-session-message>" || len(sent) != 0 {
			t.Fatalf("frame = %+v, tmux = %v", frame, sent)
		}
	case <-time.After(time.Second):
		t.Fatal("Claude did not receive frame")
	}
}

func TestCodexQueueAcceptanceAndFailure(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-codex-native", "codex", "worker")
	setPrimaryAgent(t, store, "qm-codex-native", "codex")
	if err := store.Update("qm-codex-native", func(m *state.Manifest) {
		m.Extra = map[string]json.RawMessage{"codex_thread_id": json.RawMessage(`"thread-123"`)}
	}); err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	argsPath := filepath.Join(bin, "args")
	script := "#!/bin/sh\nif [ \"$1\" = app-server ]; then printf '{\"status\":\"running\"}\\n'; exit 0; fi\nprintf '%s\\n' \"$*\" > '" + argsPath + "'\nif [ \"$CODEX_QUEUE_FAIL\" = 1 ]; then exit 1; fi\nprintf 'Queued message msg-1 for thread thread-123\\n'\n"
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	decoyDir := t.TempDir()
	decoyPath := filepath.Join(decoyDir, "called")
	decoy := "#!/bin/sh\nprintf '%s\\n' \"$*\" > '" + decoyPath + "'\nif [ \"$1\" = app-server ]; then printf '{\"status\":\"running\"}\\n'; else printf 'Queued message decoy for thread thread-123\\n'; fi\n"
	if err := os.WriteFile(filepath.Join(decoyDir, "codex"), []byte(decoy), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := store.Update("qm-codex-native", func(m *state.Manifest) {
		m.Agents[0].CLI = filepath.Join(bin, "codex")
	}); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", decoyDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("CODEX_BIN", filepath.Join(decoyDir, "codex"))
	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	if err := svc.Relay(t.Context(), "qm-codex-native", "hello\nworld"); err != nil {
		t.Fatal(err)
	}
	args, err := os.ReadFile(argsPath)
	if err != nil || string(args) != "queue --thread thread-123 --message hello\nworld\n" {
		t.Fatalf("queue args = %q, err = %v", args, err)
	}
	if len(sent) != 0 {
		t.Fatalf("queued input also reached tmux: %v", sent)
	}
	if _, err := os.Stat(decoyPath); !os.IsNotExist(err) {
		t.Fatalf("relay invoked PATH/CODEX_BIN decoy: %v", err)
	}
	if err := store.Update("qm-codex-native", func(m *state.Manifest) {
		m.Agents[0].CLI = "codex"
		m.AgentPath = bin
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(argsPath); err != nil {
		t.Fatal(err)
	}
	if err := svc.Relay(t.Context(), "qm-codex-native", "bare name"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(argsPath); err != nil {
		t.Fatalf("target AgentPath binary was not used: %v", err)
	}
	if _, err := os.Stat(decoyPath); !os.IsNotExist(err) {
		t.Fatalf("bare CLI invoked PATH decoy: %v", err)
	}
	t.Setenv("CODEX_QUEUE_FAIL", "1")
	if err := svc.Relay(t.Context(), "qm-codex-native", "again"); err == nil {
		t.Fatal("failed queue should return an error")
	}
	if len(sent) != 0 {
		t.Fatalf("failed queue retried through tmux: %v", sent)
	}
	if err := os.Remove(argsPath); err != nil {
		t.Fatal(err)
	}
	dead := newService(store, &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1}
	}})
	if err := dead.Relay(t.Context(), "qm-codex-native", "dead"); err == nil {
		t.Fatal("dead session accepted relay")
	}
	if _, err := os.Stat(argsPath); !os.IsNotExist(err) {
		t.Fatalf("dead session reached queue: %v", err)
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
	if len(sent) != 1 || sent[0] != "hello" {
		t.Fatalf("restricted Claude tmux fallback = %v", sent)
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
	if <-got != message || len(sent) != 0 {
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
