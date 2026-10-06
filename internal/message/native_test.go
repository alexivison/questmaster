//go:build linux || darwin

package message

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/coder/websocket"
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
	script := "#!/bin/sh\nif [ \"$1\" = app-server ]; then printf '{\"status\":\"running\"}\\n'; exit 0; fi\nprintf '%s\\n' \"$*\" > '" + argsPath + "'\nif [ \"$CODEX_QUEUE_HANG\" = 1 ]; then exec sleep 5; fi\nif [ \"$CODEX_QUEUE_FAIL\" = 1 ]; then exit 1; fi\nprintf 'Queued message msg-1 for thread thread-123\\n'\n"
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
	if err != nil || string(args) != "queue --thread thread-123 --message=[FROM:external] hello\nworld\n" {
		t.Fatalf("queue args = %q, err = %v", args, err)
	}
	m, err := store.Read("qm-codex-native")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.deliverCodexWithMode(t.Context(), m, "-leading"); err != nil {
		t.Fatal(err)
	}
	args, err = os.ReadFile(argsPath)
	if err != nil || string(args) != "queue --thread thread-123 --message=-leading\n" {
		t.Fatalf("leading-dash queue args = %q, err = %v", args, err)
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
	t.Setenv("CODEX_QUEUE_FAIL", "")
	t.Setenv("CODEX_QUEUE_HANG", "1")
	previousTimeout := codexQueueTimeout
	codexQueueTimeout = 100 * time.Millisecond
	t.Cleanup(func() { codexQueueTimeout = previousTimeout })
	started := time.Now()
	if err := svc.Relay(t.Context(), "qm-codex-native", "hang"); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("hung queue error = %v, want deadline exceeded", err)
	}
	if time.Since(started) > time.Second || len(sent) != 0 {
		t.Fatalf("hung queue blocked or retried through tmux: elapsed %s, tmux %v", time.Since(started), sent)
	}
	t.Setenv("CODEX_QUEUE_HANG", "")
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

func TestCodexSteerAndQueueFallback(t *testing.T) {
	for _, tt := range []struct {
		name      string
		mode      string
		wantSteer bool
		wantQueue bool
		wantError bool
		wantMode  DeliveryMode
	}{
		{name: "active turn", mode: "active", wantSteer: true, wantMode: DeliveryCodexSteer},
		{name: "no active turn queues", mode: "inactive", wantQueue: true, wantMode: DeliveryCodexQueue},
		{name: "target TUI owns active writer", mode: "active_writer", wantQueue: true, wantMode: DeliveryCodexQueue},
		{name: "turn ended before steer queues", mode: "rejected", wantSteer: true, wantQueue: true, wantMode: DeliveryCodexQueue},
		{name: "uncertain acceptance is not retried", mode: "uncertain", wantSteer: true, wantError: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			store := setupStore(t)
			createManifest(t, store, "qm-codex-steer", "worker", "worker")
			setPrimaryAgent(t, store, "qm-codex-steer", "codex")
			bin := t.TempDir()
			tracePath := filepath.Join(bin, "trace")
			if err := os.WriteFile(tracePath, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			socket, requests := startCodexTestDaemon(t, tt.mode)
			script := "#!/bin/sh\n" +
				"if [ \"$1\" = app-server ] && [ \"$2\" = daemon ]; then printf '{\"status\":\"running\",\"socketPath\":\"%s\"}\\n' \"$CODEX_TEST_SOCKET\"; exit 0; fi\n" +
				"printf 'queue %s\\n' \"$*\" >> '" + tracePath + "'; printf 'Queued message msg-1 for thread thread-123\\n'\n"
			codex := filepath.Join(bin, "codex")
			if err := os.WriteFile(codex, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := store.Update("qm-codex-steer", func(m *state.Manifest) {
				m.Agents[0].CLI = codex
				m.Extra = map[string]json.RawMessage{"codex_thread_id": json.RawMessage(`"thread-123"`)}
			}); err != nil {
				t.Fatal(err)
			}
			t.Setenv("CODEX_STEER_MODE", tt.mode)
			t.Setenv("CODEX_TEST_SOCKET", socket)
			var sent []string
			svc := newService(store, idleAndSendRunner(&sent))
			svc.Steer = true
			deliveryMode, err := svc.RelayWithMode(t.Context(), "qm-codex-steer", "hello")
			if (err != nil) != tt.wantError {
				t.Fatalf("Relay error = %v, wantError %v", err, tt.wantError)
			}
			if deliveryMode != tt.wantMode {
				t.Fatalf("delivery mode = %q, want %q", deliveryMode, tt.wantMode)
			}
			trace, err := os.ReadFile(tracePath)
			if err != nil {
				t.Fatal(err)
			}
			text := string(trace)
			if strings.Contains(text, "queue --thread thread-123") != tt.wantQueue {
				t.Fatalf("queue presence = %v, trace %q", strings.Contains(text, "queue --thread thread-123"), text)
			}
			methods := map[string]map[string]any{}
			for len(requests) > 0 {
				request := <-requests
				if request.JSONRPC != "2.0" {
					t.Fatalf("%s request used JSON-RPC version %q", request.Method, request.JSONRPC)
				}
				methods[request.Method] = request.Params
			}
			if _, ok := methods["turn/steer"]; ok != tt.wantSteer {
				t.Fatalf("steer request presence = %v, methods %v", ok, methods)
			}
			if tt.wantSteer {
				params := methods["turn/steer"]
				if params["expectedTurnId"] != "turn-1" {
					t.Fatalf("steer expectedTurnId = %v", params["expectedTurnId"])
				}
				input, ok := params["input"].([]any)
				if !ok || len(input) != 1 || input[0].(map[string]any)["text"] != "[FROM:external] hello" {
					t.Fatalf("steer input lost sender prefix: %v", params["input"])
				}
			}
			if tt.wantQueue && !strings.Contains(text, "--message=[FROM:external] hello") {
				t.Fatalf("queue fallback lost sender prefix: %q", text)
			}
			if len(sent) != 0 {
				t.Fatalf("native Codex send retried through tmux: %v", sent)
			}
		})
	}
}

type codexTestRPCRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  map[string]any  `json:"params"`
}

func startCodexTestDaemon(t *testing.T, mode string) (string, <-chan codexTestRPCRequest) {
	t.Helper()
	socket := filepath.Join("/tmp", "qm-codex-"+strconv.Itoa(os.Getpid())+"-"+strconv.FormatInt(time.Now().UnixNano(), 10)+".sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan codexTestRPCRequest, 8)
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		for {
			_, data, err := conn.Read(r.Context())
			if err != nil {
				return
			}
			var request codexTestRPCRequest
			if err := json.Unmarshal(data, &request); err != nil {
				return
			}
			if request.Method == "initialized" {
				continue
			}
			requests <- request
			var result any
			var rpcError any
			switch request.Method {
			case "initialize":
				result = map[string]any{}
			case "thread/resume":
				if mode == "active_writer" {
					rpcError = map[string]any{"code": -32600, "message": "thread already has an active writer"}
				} else {
					result = map[string]any{}
				}
			case "thread/turns/list":
				status := "inProgress"
				if mode == "inactive" {
					status = "completed"
				}
				result = map[string]any{"data": []map[string]string{{"id": "turn-1", "status": status}}}
			case "turn/steer":
				if mode == "uncertain" {
					return
				}
				if mode == "rejected" {
					rpcError = map[string]any{"code": -32600, "message": "no active turn to steer"}
				} else {
					result = map[string]string{"turnId": "turn-1"}
				}
			default:
				return
			}
			payload := map[string]any{"jsonrpc": "2.0", "id": json.RawMessage(request.ID)}
			if rpcError != nil {
				payload["error"] = rpcError
			} else {
				payload["result"] = result
			}
			payloadBytes, marshalErr := json.Marshal(payload)
			if marshalErr != nil || conn.Write(r.Context(), websocket.MessageText, payloadBytes) != nil {
				return
			}
		}
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close(); _ = listener.Close() })
	return socket, requests
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
