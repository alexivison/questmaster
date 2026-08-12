//go:build linux || darwin

package message

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestMain(m *testing.M) {
	stateRoot, err := os.MkdirTemp("", "qm-message-state-*")
	if err != nil {
		panic(err)
	}
	_ = os.Setenv("QUESTMASTER_STATE_ROOT", stateRoot)
	code := m.Run()
	_ = os.RemoveAll(stateRoot)
	os.Exit(code)
}

// ---------------------------------------------------------------------------
// Mock tmux runner
// ---------------------------------------------------------------------------

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

func setupStore(t *testing.T) *state.Store {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func createManifest(t *testing.T, store *state.Store, id, title, sessionType string) {
	t.Helper()
	m := state.Manifest{
		SessionID:   id,
		Title:       title,
		Cwd:         "/tmp",
		SessionType: sessionType,
		Agents: []state.AgentManifest{
			{Name: "claude", Role: primaryRole, CLI: "/usr/bin/claude", Window: 1},
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest %s: %v", id, err)
	}
}

func createPlainManifest(t *testing.T, store *state.Store, id, title string) {
	t.Helper()
	if err := store.Create(state.Manifest{SessionID: id, Title: title, Cwd: "/tmp"}); err != nil {
		t.Fatalf("create plain manifest %s: %v", id, err)
	}
}

func setPrimaryAgent(t *testing.T, store *state.Store, id, name string) {
	t.Helper()
	if err := store.Update(id, func(m *state.Manifest) {
		m.Agents = []state.AgentManifest{{Name: name, Role: "primary", CLI: "/usr/bin/" + name, Window: 1}}
	}); err != nil {
		t.Fatalf("set primary agent for %s: %v", id, err)
	}
}

type piActivityFixture struct {
	State       string
	Activity    string
	Recent      []string
	LastEvent   time.Time
	SessionFile string
	PiSessionID string
}

func writePiActivityState(t *testing.T, sessionID string, fixture piActivityFixture) {
	t.Helper()
	removePiActivityState(t, sessionID)
	if fixture.State == "" {
		fixture.State = "done"
	}
	if fixture.LastEvent.IsZero() {
		fixture.LastEvent = time.Now()
	}
	if err := state.SaveSessionState(sessionID, &state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    fixture.LastEvent,
		Panes: map[string]state.PaneState{
			primaryRole: {
				Role:        primaryRole,
				Agent:       "pi",
				State:       fixture.State,
				Activity:    fixture.Activity,
				Recent:      fixture.Recent,
				LastEvent:   fixture.LastEvent,
				Seq:         fixture.LastEvent.UnixNano(),
				SessionFile: fixture.SessionFile,
				PiSessionID: fixture.PiSessionID,
			},
		},
	}); err != nil {
		t.Fatalf("save Pi state: %v", err)
	}
}

func writeOpenCodeActivityState(t *testing.T, sessionID string, recent []string, activity string) {
	t.Helper()
	writeOpenCodePaneState(t, sessionID, "idle", recent, activity)
}

func writeOpenCodePaneState(t *testing.T, sessionID, paneState string, recent []string, activity string) {
	t.Helper()
	removePiActivityState(t, sessionID)
	now := time.Now().UTC()
	if err := state.SaveSessionState(sessionID, &state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    now,
		Panes: map[string]state.PaneState{
			primaryRole: {
				Role:              primaryRole,
				Agent:             "opencode",
				State:             paneState,
				Activity:          activity,
				Recent:            recent,
				LastEvent:         now,
				Seq:               now.UnixNano(),
				OpenCodeSessionID: "ses_read",
			},
		},
	}); err != nil {
		t.Fatalf("save OpenCode state: %v", err)
	}
}

func writeOpenCodePaneStateAt(t *testing.T, root, sessionID, paneState string) {
	t.Helper()
	now := time.Now().UTC()
	data, err := json.Marshal(state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    now,
		Panes: map[string]state.PaneState{
			primaryRole: {Role: primaryRole, Agent: "opencode", State: paneState, LastEvent: now},
		},
	})
	if err != nil {
		t.Fatalf("marshal OpenCode state: %v", err)
	}
	path := state.SessionStatePath(root, sessionID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir OpenCode state dir: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write OpenCode state: %v", err)
	}
}

func writePrimaryPaneState(t *testing.T, sessionID, paneState string) {
	t.Helper()
	now := time.Now().UTC()
	removePiActivityState(t, sessionID)
	if err := state.SaveSessionState(sessionID, &state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    now,
		Panes: map[string]state.PaneState{
			primaryRole: {
				Role:      primaryRole,
				Agent:     "codex",
				State:     paneState,
				Activity:  paneState,
				LastEvent: now,
				Seq:       now.UnixNano(),
			},
		},
	}); err != nil {
		t.Fatalf("save session state: %v", err)
	}
}

func removePiActivitySidecar(t *testing.T, sessionID string) {
	t.Helper()
	removePiActivityState(t, sessionID)
}

func removePiActivityState(t *testing.T, sessionID string) {
	t.Helper()
	root := state.StateRoot()
	if root == "" {
		t.Fatal("state root not resolved")
	}
	dir := state.SessionStateDir(root, sessionID)
	if err := os.RemoveAll(dir); err != nil {
		t.Fatalf("remove Pi state dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
}

func createWorkerManifest(t *testing.T, store *state.Store, id, parentID string) {
	t.Helper()
	m := state.Manifest{
		SessionID: id,
		Cwd:       "/tmp",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: primaryRole, CLI: "/usr/bin/claude", Window: 1},
		},
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"` + parentID + `"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create worker manifest %s: %v", id, err)
	}
	if err := store.AddWorker(parentID, id); err != nil {
		t.Fatalf("add worker %s to %s: %v", id, parentID, err)
	}
}

func newService(store *state.Store, runner tmux.Runner) *Service {
	return NewService(store, tmux.NewClient(runner))
}

func flagValue(args []string, flag string) string {
	for i, arg := range args {
		if arg == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func relayFilePathFromPointer(t *testing.T, pointer string) string {
	t.Helper()

	idx := strings.Index(pointer, "/")
	if idx < 0 {
		t.Fatalf("could not locate relay path in pointer: %q", pointer)
	}
	tail := pointer[idx:]
	end := strings.Index(tail, ".md")
	if end < 0 {
		t.Fatalf("could not locate relay path end in pointer: %q", pointer)
	}
	return tail[:end+3]
}

// idleAndSendRunner returns a runner that reports panes as idle
// and records send-keys calls.
func idleAndSendRunner(sent *[]string) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
			if args[len(args)-1] == "#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}" {
				return "999999\t" + args[2], nil
			}
			return "0", nil // pane idle
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			// Record literal text sends (not Enter)
			for i, a := range args {
				if a == "-l" && i+2 < len(args) {
					*sent = append(*sent, args[i+2])
				}
			}
			return "", nil
		}
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil // session exists
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

func claudeNativeRunner(pid int, canonical string, sent *[]string) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "has-session":
			return "", nil
		case "list-panes":
			return "0 0 primary", nil
		case "display-message":
			if args[len(args)-1] == "#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}" {
				return strconv.Itoa(pid) + "\t" + canonical, nil
			}
			return "0", nil
		case "send-keys":
			for i, arg := range args {
				if arg == "-l" && i+2 < len(args) {
					*sent = append(*sent, args[i+2])
				}
			}
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

func claudeNativeSocket(t *testing.T, pid int, canonical string) <-chan []byte {
	t.Helper()
	configDir := t.TempDir()
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := os.Mkdir(sessionsDir, 0o700); err != nil {
		t.Fatalf("mkdir Claude sessions: %v", err)
	}
	socketFile, err := os.CreateTemp("/tmp", "qm-claude-inbox-")
	if err != nil {
		t.Fatalf("create Claude socket path: %v", err)
	}
	socketPath := socketFile.Name()
	if err := socketFile.Close(); err != nil {
		t.Fatalf("close Claude socket path: %v", err)
	}
	if err := os.Remove(socketPath); err != nil {
		t.Fatalf("remove Claude socket path: %v", err)
	}
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatalf("listen Claude socket: %v", err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		t.Fatalf("chmod Claude socket: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)

	record, err := json.Marshal(map[string]any{
		"pid":                 pid,
		"peerProtocol":        1,
		"tmux":                canonical,
		"messagingSocketPath": socketPath,
	})
	if err != nil {
		t.Fatalf("marshal Claude session record: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sessionsDir, strconv.Itoa(pid)+".json"), record, 0o600); err != nil {
		t.Fatalf("write Claude session record: %v", err)
	}

	received := make(chan []byte, 1)
	go func() {
		conn, err := listener.AcceptUnix()
		if err != nil {
			return
		}
		defer conn.Close()
		data, _ := io.ReadAll(conn)
		received <- data
	}()
	return received
}

func rewriteClaudeSessionRecord(t *testing.T, pid int, update func(map[string]any)) {
	t.Helper()
	path := filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), "sessions", strconv.Itoa(pid)+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read Claude session record: %v", err)
	}
	var record map[string]any
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatalf("decode Claude session record: %v", err)
	}
	update(record)
	data, err = json.Marshal(record)
	if err != nil {
		t.Fatalf("encode Claude session record: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write Claude session record: %v", err)
	}
}

func claudeSocketPath(t *testing.T, pid int) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), "sessions", strconv.Itoa(pid)+".json"))
	if err != nil {
		t.Fatalf("read Claude session record: %v", err)
	}
	var record struct {
		Socket string `json:"messagingSocketPath"`
	}
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatalf("decode Claude session record: %v", err)
	}
	return record.Socket
}

type writeResultConn struct {
	n   int
	err error
}

func (c *writeResultConn) Read([]byte) (int, error)         { return 0, io.EOF }
func (c *writeResultConn) Write([]byte) (int, error)        { return c.n, c.err }
func (c *writeResultConn) Close() error                     { return nil }
func (c *writeResultConn) LocalAddr() net.Addr              { return &net.UnixAddr{Net: "unix"} }
func (c *writeResultConn) RemoteAddr() net.Addr             { return &net.UnixAddr{Net: "unix"} }
func (c *writeResultConn) SetDeadline(time.Time) error      { return nil }
func (c *writeResultConn) SetReadDeadline(time.Time) error  { return nil }
func (c *writeResultConn) SetWriteDeadline(time.Time) error { return nil }

// ---------------------------------------------------------------------------
// needsFileIndirection tests
// ---------------------------------------------------------------------------

func TestNeedsFileIndirection_ShortMessage(t *testing.T) {
	t.Parallel()
	if needsFileIndirection("hello") {
		t.Fatal("short message should not need file indirection")
	}
}

func TestNeedsFileIndirection_LongMessage(t *testing.T) {
	t.Parallel()
	long := strings.Repeat("x", LargeMessageThreshold+1)
	if !needsFileIndirection(long) {
		t.Fatal("long message should need file indirection")
	}
}

func TestNeedsFileIndirection_MultilineMessage(t *testing.T) {
	t.Parallel()
	if !needsFileIndirection("line1\nline2") {
		t.Fatal("multiline message should need file indirection")
	}
}

func TestNeedsFileIndirection_ExactThreshold(t *testing.T) {
	t.Parallel()
	exact := strings.Repeat("x", LargeMessageThreshold)
	if needsFileIndirection(exact) {
		t.Fatal("message at exact threshold should not need file indirection")
	}
}

// ---------------------------------------------------------------------------
// writeRelayFile tests
// ---------------------------------------------------------------------------

func TestWriteRelayFile_CreatesFileWithContent(t *testing.T) {
	t.Parallel()
	path, err := writeRelayFile("test content")
	if err != nil {
		t.Fatalf("writeRelayFile: %v", err)
	}
	t.Cleanup(func() { os.Remove(path) })

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read file: %v", err)
	}
	if string(data) != "test content\n" {
		t.Fatalf("expected 'test content\\n', got %q", string(data))
	}
}

func TestWriteRelayFile_ReturnsPointerMessage(t *testing.T) {
	t.Parallel()
	path, err := writeRelayFile("content")
	if err != nil {
		t.Fatalf("writeRelayFile: %v", err)
	}
	t.Cleanup(func() { os.Remove(path) })

	pointer := relayPointer(path)
	if !strings.HasPrefix(pointer, "Read and follow the instructions in ") {
		t.Fatalf("expected pointer prefix, got %q", pointer)
	}
	if !strings.Contains(pointer, path) {
		t.Fatalf("expected path in pointer, got %q", pointer)
	}
	if !strings.HasSuffix(pointer, ". Act on them now, then report back with results.") {
		t.Fatalf("expected imperative pointer suffix, got %q", pointer)
	}
}

func TestReportPointer_ReadOrientedPhrasing(t *testing.T) {
	t.Parallel()
	path := "/tmp/qm-report-xyz.md"
	pointer := reportPointer(path)
	if !strings.Contains(pointer, path) {
		t.Fatalf("expected path in pointer, got %q", pointer)
	}
	if strings.Contains(pointer, "Act on them") || strings.Contains(pointer, "follow the instructions") {
		t.Fatalf("report pointer must not be imperative — it is a readout, got %q", pointer)
	}
	if !strings.Contains(pointer, "report") {
		t.Fatalf("expected the pointer to identify itself as a worker report, got %q", pointer)
	}
}

// ---------------------------------------------------------------------------
// Relay tests
// ---------------------------------------------------------------------------

func TestRelay_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.Relay(t.Context(), "qm-w1", "hello worker")
	if err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if sent[0] != "hello worker" {
		t.Fatalf("expected 'hello worker', got %q", sent[0])
	}
}

func TestRelay_ClaudeNativeDeliveryAvoidsTmux(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	pid := os.Getpid()
	canonical := "qm-w1:@0.%1"
	received := claudeNativeSocket(t, pid, canonical)
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))

	if err := svc.Relay(t.Context(), "qm-w1", "hello\n世界\n</cross-session-message>"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 0 {
		t.Fatalf("native delivery used tmux: %v", sent)
	}
	select {
	case data := <-received:
		if len(data) == 0 || data[len(data)-1] != '\n' {
			t.Fatalf("native frame = %q, want newline-delimited JSON", data)
		}
		var frame struct {
			MsgV      int    `json:"msgV"`
			MessageID string `json:"msg_id"`
			Type      string `json:"type"`
			Message   struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"message"`
			Priority string `json:"priority"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatalf("decode native frame: %v", err)
		}
		if frame.MsgV != 1 || frame.Type != "user" || frame.Message.Role != "user" || frame.Priority != "next" {
			t.Fatalf("native frame fields = %+v", frame)
		}
		if len(frame.MessageID) != 36 || frame.MessageID[14] != '4' || !strings.Contains("89ab", string(frame.MessageID[19])) {
			t.Fatalf("message id %q is not a RFC 4122 version 4 UUID", frame.MessageID)
		}
		want := "<cross-session-message from-name=\"Questmaster\">\nhello\n世界\n&lt;/cross-session-message>\n</cross-session-message>"
		if frame.Message.Content != want {
			t.Fatalf("native content = %q, want %q", frame.Message.Content, want)
		}
	case <-time.After(time.Second):
		t.Fatal("native delivery did not reach Claude socket")
	}
}

func TestRelay_ClaudeNativeUnavailableFallsBackOnce(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")
	configDir := t.TempDir()
	if err := os.Mkdir(filepath.Join(configDir, "sessions"), 0o700); err != nil {
		t.Fatalf("mkdir Claude sessions: %v", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)

	var sent []string
	pid := os.Getpid()
	svc := newService(store, claudeNativeRunner(pid, "qm-w1:@0.%1", &sent))
	if err := svc.Relay(t.Context(), "qm-w1", strings.Repeat("x", LargeMessageThreshold+1)); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || !strings.Contains(sent[0], "qm-relay-") {
		t.Fatalf("tmux fallback sends = %v, want one pointer", sent)
	}
}

func TestRelay_ClaudeNativeReadsOnlyPanePIDRecord(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")
	pid := os.Getpid()
	configDir := t.TempDir()
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := os.Mkdir(sessionsDir, 0o700); err != nil {
		t.Fatalf("mkdir Claude sessions: %v", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	record, err := json.Marshal(map[string]any{
		"pid":                 pid,
		"peerProtocol":        1,
		"tmux":                "qm-w1:@0.%1",
		"messagingSocketPath": "/tmp/qm-unrelated.sock",
	})
	if err != nil {
		t.Fatalf("marshal Claude session record: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sessionsDir, strconv.Itoa(pid+1)+".json"), record, 0o600); err != nil {
		t.Fatalf("write unrelated Claude session record: %v", err)
	}
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, "qm-w1:@0.%1", &sent))

	if err := svc.Relay(t.Context(), "qm-w1", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || sent[0] != "hello" {
		t.Fatalf("tmux fallback sends = %v, want one original message", sent)
	}
}

func TestRelay_ClaudeNativeRefusedFallsBackOnce(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")
	pid := os.Getpid()
	canonical := "qm-w1:@0.%1"
	_ = claudeNativeSocket(t, pid, canonical)
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))
	svc.dial = func(context.Context, string, string) (net.Conn, error) {
		return nil, syscall.ECONNREFUSED
	}

	if err := svc.Relay(t.Context(), "qm-w1", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || sent[0] != "hello" {
		t.Fatalf("tmux fallback sends = %v, want one original message", sent)
	}
}

func TestRelay_ClaudeNativeUnsupportedPeerProtocolFallsBackOnce(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")
	pid := os.Getpid()
	canonical := "qm-w1:@0.%1"
	_ = claudeNativeSocket(t, pid, canonical)
	rewriteClaudeSessionRecord(t, pid, func(record map[string]any) { record["peerProtocol"] = 2 })
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))

	if err := svc.Relay(t.Context(), "qm-w1", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || sent[0] != "hello" {
		t.Fatalf("unsupported protocol fallback sends = %v, want one original message", sent)
	}
}

func TestRelay_ClaudeNativeTerminalErrorsDoNotFallback(t *testing.T) {
	for name, setup := range map[string]func(t *testing.T, svc *Service, pid int){
		"pid mismatch": func(t *testing.T, _ *Service, pid int) {
			rewriteClaudeSessionRecord(t, pid, func(record map[string]any) { record["pid"] = pid + 1 })
		},
		"tmux mismatch": func(t *testing.T, _ *Service, pid int) {
			rewriteClaudeSessionRecord(t, pid, func(record map[string]any) { record["tmux"] = "qm-other:@0.%1" })
		},
		"socket permissions": func(t *testing.T, _ *Service, pid int) {
			if err := os.Chmod(claudeSocketPath(t, pid), 0o644); err != nil {
				t.Fatalf("chmod Claude socket: %v", err)
			}
		},
		"sessions directory permissions": func(t *testing.T, _ *Service, _ int) {
			if err := os.Chmod(filepath.Join(os.Getenv("CLAUDE_CONFIG_DIR"), "sessions"), 0o770); err != nil {
				t.Fatalf("chmod Claude sessions: %v", err)
			}
		},
		"partial write": func(_ *testing.T, svc *Service, _ int) {
			svc.dial = func(context.Context, string, string) (net.Conn, error) {
				return &writeResultConn{n: 1}, nil
			}
		},
		"write timeout": func(_ *testing.T, svc *Service, _ int) {
			svc.dial = func(context.Context, string, string) (net.Conn, error) {
				return &writeResultConn{err: context.DeadlineExceeded}, nil
			}
		},
		"dial cancellation": func(_ *testing.T, svc *Service, _ int) {
			svc.dial = func(context.Context, string, string) (net.Conn, error) {
				return nil, context.Canceled
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			store := setupStore(t)
			createManifest(t, store, "qm-w1", "worker1", "worker")
			pid := os.Getpid()
			canonical := "qm-w1:@0.%1"
			_ = claudeNativeSocket(t, pid, canonical)
			var sent []string
			svc := newService(store, claudeNativeRunner(pid, canonical, &sent))
			setup(t, svc, pid)

			if err := svc.Relay(t.Context(), "qm-w1", "hello"); err == nil {
				t.Fatal("relay succeeded, want terminal native error")
			}
			if len(sent) != 0 {
				t.Fatalf("terminal native error used tmux: %v", sent)
			}
		})
	}
}

func TestRelay_ClaudeNativePaneIdentityFailureDoesNotFallback(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	var sent []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "has-session":
			return "", nil
		case "list-panes":
			return "0 0 primary", nil
		case "display-message":
			return "not-a-pane-identity", nil
		case "send-keys":
			for i, arg := range args {
				if arg == "-l" && i+2 < len(args) {
					sent = append(sent, args[i+2])
				}
			}
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)

	if err := svc.Relay(t.Context(), "qm-w1", "hello"); err == nil {
		t.Fatal("relay succeeded, want pane identity error")
	}
	if len(sent) != 0 {
		t.Fatalf("pane identity error used tmux fallback: %v", sent)
	}
}

func TestRelay_ClaudeNativeStalePIDFallsBackOnce(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")
	pid := 999999
	canonical := "qm-w1:@0.%1"
	configDir := t.TempDir()
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := os.Mkdir(sessionsDir, 0o700); err != nil {
		t.Fatalf("mkdir Claude sessions: %v", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	record, err := json.Marshal(map[string]any{
		"pid":                 pid,
		"peerProtocol":        1,
		"tmux":                canonical,
		"messagingSocketPath": "/tmp/qm-unused.sock",
	})
	if err != nil {
		t.Fatalf("marshal Claude session record: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sessionsDir, strconv.Itoa(pid)+".json"), record, 0o600); err != nil {
		t.Fatalf("write Claude session record: %v", err)
	}
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))

	if err := svc.Relay(t.Context(), "qm-w1", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || sent[0] != "hello" {
		t.Fatalf("stale pid fallback sends = %v, want one original message", sent)
	}
}

func TestClaudeFrame_RejectsOversizeRawMessage(t *testing.T) {
	if _, err := claudeFrame(strings.Repeat("x", claudeMaxFrameBytes+1)); err == nil {
		t.Fatal("oversize raw Claude message succeeded")
	}
}

func TestClaudeFrame_RejectsOversizeEncodedFrame(t *testing.T) {
	if _, err := claudeFrame(strings.Repeat("x", claudeMaxFrameBytes)); err == nil {
		t.Fatal("oversize Claude frame succeeded")
	}
}

func TestClaudeRecord_RejectsOversizeRecord(t *testing.T) {
	configDir := t.TempDir()
	sessionsDir := filepath.Join(configDir, "sessions")
	if err := os.Mkdir(sessionsDir, 0o700); err != nil {
		t.Fatalf("mkdir Claude sessions: %v", err)
	}
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	pid := os.Getpid()
	path := filepath.Join(sessionsDir, strconv.Itoa(pid)+".json")
	if err := os.WriteFile(path, []byte(strings.Repeat("x", claudeMaxRecordBytes+1)), 0o600); err != nil {
		t.Fatalf("write Claude session record: %v", err)
	}
	if _, err := claudeRecord(pid, "qm-w1:@0.%1"); err == nil || !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("claudeRecord oversized error = %v, want bounded-read rejection", err)
	}
}

func TestRelayFrom_PrefixesInlineMessage(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.RelayFrom(t.Context(), "qm-master", "qm-w1", "hello worker")
	if err != nil {
		t.Fatalf("relay from: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	expected := "[FROM:qm-master] hello worker"
	if sent[0] != expected {
		t.Fatalf("expected %q, got %q", expected, sent[0])
	}
}

func TestRelay_OpenCodeRequiresIdleHookState(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-opencode-relay-busy"
	createManifest(t, store, sessionID, "opencode worker", "worker")
	setPrimaryAgent(t, store, sessionID, "opencode")
	writeOpenCodePaneStateAt(t, store.Root(), sessionID, "working")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.Relay(t.Context(), sessionID, "hello worker")
	if err == nil || !strings.Contains(err.Error(), "requires idle or done") {
		t.Fatalf("relay error = %v, want requires idle or done", err)
	}
	if len(sent) != 0 {
		t.Fatalf("unsafe OpenCode relay sent input: %v", sent)
	}
}

func TestRelay_OpenCodeLegacyIdleFallbackSkipsPaneIdentity(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-opencode-relay-idle"
	createManifest(t, store, sessionID, "opencode worker", "worker")
	setPrimaryAgent(t, store, sessionID, "opencode")
	writeOpenCodePaneStateAt(t, store.Root(), sessionID, "idle")

	var sent []string
	var identityCalls int
	runner := idleAndSendRunner(&sent)
	run := runner.fn
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if args[0] == "display-message" && args[len(args)-1] == "#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}" {
			identityCalls++
		}
		return run(ctx, args...)
	}
	svc := newService(store, runner)
	if err := svc.Relay(t.Context(), sessionID, "hello worker"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 || sent[0] != "hello worker" {
		t.Fatalf("sent = %v, want hello worker", sent)
	}
	if identityCalls != 0 {
		t.Fatalf("legacy fallback queried pane identity %d times", identityCalls)
	}
}

func TestRelay_OpenCodeAllowsFreshDoneHookState(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-opencode-relay-done"
	createManifest(t, store, sessionID, "opencode worker", "worker")
	setPrimaryAgent(t, store, sessionID, "opencode")
	writeOpenCodePaneStateAt(t, store.Root(), sessionID, "done")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	if err := svc.Relay(t.Context(), sessionID, "hello worker"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 || sent[0] != "hello worker" {
		t.Fatalf("sent = %v, want hello worker", sent)
	}
}

func TestRelay_OpenCodeUsesInjectedStoreRoot(t *testing.T) {
	store := setupStore(t)
	sessionID := "qm-opencode-store-root"
	createManifest(t, store, sessionID, "opencode worker", "worker")
	setPrimaryAgent(t, store, sessionID, "opencode")
	writeOpenCodePaneStateAt(t, store.Root(), sessionID, "idle")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	if err := svc.Relay(t.Context(), sessionID, "hello worker"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) != 1 || sent[0] != "hello worker" {
		t.Fatalf("sent = %v, want one tmux relay", sent)
	}
}

func TestRelay_OpenCodeNativeDeliveryAvoidsTmux(t *testing.T) {
	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		if r.Method != http.MethodPost || r.URL.Path != "/session/ses_native/prompt_async" || r.URL.RawQuery != "" {
			t.Errorf("request = %s %s?%s", r.Method, r.URL.Path, r.URL.RawQuery)
		}
		if got, want := r.Header.Get("x-opencode-directory"), "%2Ftmp%2Fwork%20dir%2Bnative"; got != want {
			t.Errorf("directory header = %q, want %q", got, want)
		}
		username, password, ok := r.BasicAuth()
		if !ok || username != "native-user" || password != "native-password" {
			t.Errorf("basic auth = (%q, %q, %v)", username, password, ok)
		}
		if got := r.Header.Get("Content-Type"); got != "application/json" {
			t.Errorf("Content-Type = %q", got)
		}
		var body struct {
			Agent string `json:"agent"`
			Parts []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"parts"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode body: %v", err)
		} else if body.Agent != "questmaster-worker" || len(body.Parts) != 1 || body.Parts[0].Type != "text" || body.Parts[0].Text != strings.Repeat("x", LargeMessageThreshold+1) {
			t.Errorf("body = %+v", body)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	t.Setenv("OPENCODE_SERVER_USERNAME", "native-user")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "native-password")

	store, svc, sent := newOpenCodeNativeService(t, server.URL, os.Getpid(), "working")
	if err := store.Update("qm-opencode-native", func(m *state.Manifest) { m.Cwd = "/tmp/work dir+native" }); err != nil {
		t.Fatalf("set cwd: %v", err)
	}
	if err := svc.Relay(t.Context(), "qm-opencode-native", strings.Repeat("x", LargeMessageThreshold+1)); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if requests != 1 || len(*sent) != 0 {
		t.Fatalf("native requests=%d tmux=%v, want native-only delivery", requests, *sent)
	}
}

func TestRelay_OpenCodeNativeDeliveryUsesDefaultPasswordUsername(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		username, password, ok := r.BasicAuth()
		if !ok || username != "opencode" || password != "native-password" {
			t.Errorf("basic auth = (%q, %q, %v)", username, password, ok)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	t.Setenv("OPENCODE_SERVER_USERNAME", "")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "native-password")

	_, svc, sent := newOpenCodeNativeService(t, server.URL, os.Getpid(), "idle")
	if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatalf("native delivery used tmux: %v", *sent)
	}
}

func TestRelay_OpenCodeNativeDeliveryOmitsAuthWithoutPassword(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("Authorization = %q, want empty", got)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()
	t.Setenv("OPENCODE_SERVER_USERNAME", "native-user")
	t.Setenv("OPENCODE_SERVER_PASSWORD", "")

	_, svc, sent := newOpenCodeNativeService(t, server.URL, os.Getpid(), "idle")
	if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatalf("native delivery used tmux: %v", *sent)
	}
}

func TestRelay_OpenCodeNativeUnavailableFallsBackWithMatchingPane(t *testing.T) {
	for name, mutate := range map[string]func(*state.PaneState){
		"missing endpoint": func(p *state.PaneState) { p.OpenCodeServerURL = "" },
		"invalid endpoint": func(p *state.PaneState) { p.OpenCodeServerURL = "https://127.0.0.1:4444" },
		"invalid session":  func(p *state.PaneState) { p.OpenCodeSessionID = "bad/path" },
		"missing agent":    func(p *state.PaneState) { p.OpenCodeAgent = "" },
	} {
		t.Run(name, func(t *testing.T) {
			store, svc, sent := newOpenCodeNativeService(t, "http://127.0.0.1:4444", os.Getpid(), "idle")
			pane := openCodeNativePane(t, store, "qm-opencode-native")
			mutate(pane)
			writeOpenCodeNativeStateAt(t, store.Root(), "qm-opencode-native", *pane)
			if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err != nil {
				t.Fatalf("relay: %v", err)
			}
			if len(*sent) != 1 || (*sent)[0] != "hello" {
				t.Fatalf("tmux fallback = %v, want one original message", *sent)
			}
		})
	}

	t.Run("connection refused", func(t *testing.T) {
		_, svc, sent := newOpenCodeNativeService(t, "http://127.0.0.1:4444", os.Getpid(), "idle")
		svc.dial = func(context.Context, string, string) (net.Conn, error) { return nil, syscall.ECONNREFUSED }
		if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err != nil {
			t.Fatalf("relay: %v", err)
		}
		if len(*sent) != 1 || (*sent)[0] != "hello" {
			t.Fatalf("refused fallback = %v, want one original message", *sent)
		}
	})
}

func TestRelay_OpenCodeNativePIDMismatchDoesNotFallback(t *testing.T) {
	store, svc, sent := newOpenCodeNativeService(t, "http://127.0.0.1:4444", os.Getpid(), "idle")
	pane := openCodeNativePane(t, store, "qm-opencode-native")
	pane.OpenCodePID++
	writeOpenCodeNativeStateAt(t, store.Root(), "qm-opencode-native", *pane)

	err := svc.Relay(t.Context(), "qm-opencode-native", "hello")
	if err == nil || !strings.Contains(err.Error(), "does not match hook pid") {
		t.Fatalf("relay error = %v, want pane generation mismatch", err)
	}
	if len(*sent) != 0 {
		t.Fatalf("pane generation mismatch used tmux: %v", *sent)
	}
}

func TestRelay_OpenCodeNativeFallbackPaneIdentityFailureDoesNotFallback(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-opencode-native", "opencode", "worker")
	setPrimaryAgent(t, store, "qm-opencode-native", "opencode")
	writeOpenCodeNativeStateAt(t, store.Root(), "qm-opencode-native", state.PaneState{
		Role: primaryRole, Agent: "opencode", State: "idle", OpenCodePID: os.Getpid(),
	})
	var sent []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "has-session":
			return "", nil
		case "list-panes":
			return "0 0 primary", nil
		case "display-message":
			return "invalid identity", nil
		case "send-keys":
			sent = append(sent, "unexpected")
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	err := newService(store, runner).Relay(t.Context(), "qm-opencode-native", "hello")
	if err == nil || !strings.Contains(err.Error(), "resolve OpenCode pane identity for relay") {
		t.Fatalf("relay error = %v, want pane identity failure", err)
	}
	if len(sent) != 0 {
		t.Fatalf("pane identity failure used tmux: %v", sent)
	}
}

func TestRelay_OpenCodeNativeTerminalErrorsDoNotFallback(t *testing.T) {
	for name, handler := range map[string]http.HandlerFunc{
		"non-204": func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusUnauthorized) },
		"redirect": func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Location", "http://127.0.0.1:1/other")
			w.WriteHeader(http.StatusFound)
		},
		"timeout": func(_ http.ResponseWriter, _ *http.Request) { time.Sleep(2 * openCodeNativeTimeout) },
	} {
		t.Run(name, func(t *testing.T) {
			server := httptest.NewServer(handler)
			defer server.Close()
			_, svc, sent := newOpenCodeNativeService(t, server.URL, os.Getpid(), "working")
			if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err == nil {
				t.Fatal("relay succeeded, want terminal native error")
			}
			if len(*sent) != 0 {
				t.Fatalf("terminal native error used tmux: %v", *sent)
			}
		})
	}
}

func TestRelay_OpenCodeNativeIdentityAndInputFailuresDoNotFallback(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer server.Close()

	t.Run("pane identity", func(t *testing.T) {
		store := setupStore(t)
		createManifest(t, store, "qm-opencode-native", "opencode", "worker")
		setPrimaryAgent(t, store, "qm-opencode-native", "opencode")
		writeOpenCodeNativeStateAt(t, store.Root(), "qm-opencode-native", state.PaneState{
			Role: primaryRole, Agent: "opencode", State: "idle", OpenCodeServerURL: server.URL,
			OpenCodeSessionID: "ses_native", OpenCodeAgent: "questmaster-worker", OpenCodePID: os.Getpid(),
		})
		var sent []string
		runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			switch args[0] {
			case "has-session":
				return "", nil
			case "list-panes":
				return "0 0 primary", nil
			case "display-message":
				return "invalid identity", nil
			case "send-keys":
				sent = append(sent, "unexpected")
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}}
		if err := newService(store, runner).Relay(t.Context(), "qm-opencode-native", "hello"); err == nil {
			t.Fatal("relay succeeded, want pane identity error")
		}
		if len(sent) != 0 {
			t.Fatalf("identity failure used tmux: %v", sent)
		}
	})

	t.Run("oversize input", func(t *testing.T) {
		_, svc, sent := newOpenCodeNativeService(t, server.URL, os.Getpid(), "idle")
		if err := svc.Relay(t.Context(), "qm-opencode-native", strings.Repeat("x", openCodeMaxPromptBytes+1)); err == nil {
			t.Fatal("relay succeeded with an oversized OpenCode prompt")
		}
		if len(*sent) != 0 {
			t.Fatalf("oversized input used tmux: %v", *sent)
		}
	})
}

func TestRelay_OpenCodeNativePostConnectErrorDoesNotFallback(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer listener.Close()
	go func() {
		conn, err := listener.Accept()
		if err == nil {
			_ = conn.Close()
		}
	}()
	_, svc, sent := newOpenCodeNativeService(t, "http://"+listener.Addr().String(), os.Getpid(), "idle")
	if err := svc.Relay(t.Context(), "qm-opencode-native", "hello"); err == nil {
		t.Fatal("relay succeeded, want post-connect native error")
	}
	if len(*sent) != 0 {
		t.Fatalf("post-connect error used tmux: %v", *sent)
	}
}

func TestOpenCodePromptEndpointRejectsUnsafeURLsAndRewritesPath(t *testing.T) {
	for _, raw := range []string{
		"https://127.0.0.1:4444",
		"http://localhost:4444",
		"http://127.0.0.1",
		"http://user@127.0.0.1:4444",
		"http://127.0.0.1:4444?query=1",
		"http://127.0.0.1:4444?",
		"http://127.0.0.1:4444#fragment",
	} {
		if _, err := openCodePromptEndpoint(raw, "ses_native"); !errors.Is(err, errNativeUnavailable) {
			t.Fatalf("endpoint %q error = %v, want unavailable", raw, err)
		}
	}
	endpoint, err := openCodePromptEndpoint("http://127.0.0.1:4444/not-the-api", "ses_native")
	if err != nil {
		t.Fatalf("valid endpoint: %v", err)
	}
	if got, want := endpoint.String(), "http://127.0.0.1:4444/session/ses_native/prompt_async"; got != want {
		t.Fatalf("endpoint = %q, want %q", got, want)
	}
}

func newOpenCodeNativeService(t *testing.T, serverURL string, pid int, paneState string) (*state.Store, *Service, *[]string) {
	t.Helper()
	store := setupStore(t)
	createManifest(t, store, "qm-opencode-native", "opencode", "worker")
	setPrimaryAgent(t, store, "qm-opencode-native", "opencode")
	writeOpenCodeNativeStateAt(t, store.Root(), "qm-opencode-native", state.PaneState{
		Role: primaryRole, Agent: "opencode", State: paneState, OpenCodeServerURL: serverURL,
		OpenCodeSessionID: "ses_native", OpenCodeAgent: "questmaster-worker", OpenCodePID: pid,
	})
	sent := new([]string)
	return store, newService(store, claudeNativeRunner(pid, "qm-opencode-native:@0.%1", sent)), sent
}

func openCodeNativePane(t *testing.T, store *state.Store, sessionID string) *state.PaneState {
	t.Helper()
	ss, err := state.LoadSessionStateAt(store.Root(), sessionID)
	if err != nil || ss == nil {
		t.Fatalf("load native state: %v %+v", err, ss)
	}
	pane := ss.Panes[primaryRole]
	return &pane
}

func writeOpenCodeNativeStateAt(t *testing.T, root, sessionID string, pane state.PaneState) {
	t.Helper()
	now := time.Now().UTC()
	pane.LastEvent = now
	pane.Seq = now.UnixNano()
	data, err := json.Marshal(state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    now,
		Panes:     map[string]state.PaneState{primaryRole: pane},
	})
	if err != nil {
		t.Fatalf("marshal native state: %v", err)
	}
	path := state.SessionStatePath(root, sessionID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir native state: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write native state: %v", err)
	}
}

func newPiRuntimeService(t *testing.T) (*state.Store, *Service, *[]string, string, string) {
	t.Helper()
	runtimeDir, err := os.MkdirTemp("/tmp", "qm-pi-native-")
	if err != nil {
		t.Fatalf("create Pi runtime dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(runtimeDir) })
	sessionID := filepath.Base(runtimeDir)
	store := setupStore(t)
	createManifest(t, store, sessionID, "pi", "worker")
	setPrimaryAgent(t, store, sessionID, "pi")
	sent := new([]string)
	return store, newService(store, idleAndSendRunner(sent)), sent, sessionID, filepath.Join(runtimeDir, piSocketFileName)
}

func newPiNativeService(t *testing.T, respond func(piMessageRequest, net.Conn)) (*state.Store, *Service, *[]string, string) {
	t.Helper()
	store, svc, sent, _, socketPath := newPiRuntimeService(t)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatalf("listen Pi socket: %v", err)
	}
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		t.Fatalf("chmod Pi socket: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	go func() {
		conn, err := listener.AcceptUnix()
		if err != nil {
			return
		}
		defer conn.Close()
		line, err := bufio.NewReader(conn).ReadBytes('\n')
		if err != nil {
			return
		}
		var request piMessageRequest
		if err := json.Unmarshal(line, &request); err != nil {
			return
		}
		respond(request, conn)
	}()
	return store, svc, sent, socketPath
}

func TestRelay_PiNativeDeliveryAvoidsTmuxAndFileIndirection(t *testing.T) {
	received := make(chan piMessageRequest, 1)
	message := strings.Repeat("x", LargeMessageThreshold+1) + "\n世界"
	_, svc, sent, socketPath := newPiNativeService(t, func(request piMessageRequest, conn net.Conn) {
		received <- request
		_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"submitted"}` + "\n"))
	})
	sessionID := filepath.Base(filepath.Dir(socketPath))
	if err := svc.Relay(t.Context(), sessionID, message); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatalf("native Pi delivery used tmux: %v", *sent)
	}
	select {
	case request := <-received:
		if request.Message != message {
			t.Fatalf("Pi message = %q, want logical original %q", request.Message, message)
		}
		if len(request.ID) != 36 || request.ID[14] != '4' {
			t.Fatalf("Pi request id %q is not a v4 UUID", request.ID)
		}
	case <-time.After(time.Second):
		t.Fatal("native Pi target did not receive a request")
	}
}

func TestRelay_PiNativeUnavailableFallsBack(t *testing.T) {
	_, svc, sent, sessionID, _ := newPiRuntimeService(t)
	if err := svc.Relay(t.Context(), sessionID, strings.Repeat("x", LargeMessageThreshold+1)); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(*sent) != 1 || !strings.Contains((*sent)[0], "qm-relay-") {
		t.Fatalf("tmux fallback = %v, want one pointer", *sent)
	}
}

func TestRelay_PiNativeConnectionRefusedFallsBack(t *testing.T) {
	_, svc, sent, socketPath := newPiNativeService(t, func(piMessageRequest, net.Conn) {})
	svc.dial = func(context.Context, string, string) (net.Conn, error) { return nil, syscall.ECONNREFUSED }
	sessionID := filepath.Base(filepath.Dir(socketPath))
	if err := svc.Relay(t.Context(), sessionID, "hello"); err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(*sent) != 1 || (*sent)[0] != "hello" {
		t.Fatalf("tmux fallback = %v, want one original message", *sent)
	}
}

func TestRelay_PiNativeSecurityAndWriteFailuresDoNotFallback(t *testing.T) {
	for name, setup := range map[string]func(t *testing.T, svc *Service, socketPath string){
		"socket mode": func(t *testing.T, _ *Service, socketPath string) {
			if err := os.Chmod(socketPath, 0o644); err != nil {
				t.Fatalf("chmod Pi socket: %v", err)
			}
		},
		"partial write": func(_ *testing.T, svc *Service, _ string) {
			svc.dial = func(context.Context, string, string) (net.Conn, error) { return &writeResultConn{n: 1}, nil }
		},
		"write deadline": func(_ *testing.T, svc *Service, _ string) {
			svc.dial = func(context.Context, string, string) (net.Conn, error) {
				return &writeResultConn{err: context.DeadlineExceeded}, nil
			}
		},
	} {
		t.Run(name, func(t *testing.T) {
			_, svc, sent, socketPath := newPiNativeService(t, func(piMessageRequest, net.Conn) {})
			setup(t, svc, socketPath)
			sessionID := filepath.Base(filepath.Dir(socketPath))
			if err := svc.Relay(t.Context(), sessionID, "hello"); err == nil {
				t.Fatal("relay succeeded, want terminal native error")
			}
			if len(*sent) != 0 {
				t.Fatalf("terminal Pi native error used tmux: %v", *sent)
			}
		})
	}

	t.Run("unsafe stale path", func(t *testing.T) {
		_, svc, sent, sessionID, socketPath := newPiRuntimeService(t)
		if err := os.WriteFile(socketPath, []byte("not a socket"), 0o600); err != nil {
			t.Fatalf("write unsafe Pi path: %v", err)
		}
		if err := svc.Relay(t.Context(), sessionID, "hello"); err == nil {
			t.Fatal("relay succeeded through unsafe Pi path")
		}
		if len(*sent) != 0 {
			t.Fatalf("unsafe Pi path used tmux: %v", *sent)
		}
	})

	t.Run("unsafe runtime directory", func(t *testing.T) {
		_, svc, sent, sessionID, socketPath := newPiRuntimeService(t)
		if err := os.Chmod(filepath.Dir(socketPath), 0o777); err != nil {
			t.Fatalf("chmod Pi runtime directory: %v", err)
		}
		if err := svc.Relay(t.Context(), sessionID, "hello"); err == nil {
			t.Fatal("relay succeeded through unsafe Pi runtime directory")
		}
		if len(*sent) != 0 {
			t.Fatalf("unsafe Pi runtime directory used tmux: %v", *sent)
		}
	})
}

func TestRelay_PiNativePostConnectErrorsDoNotFallback(t *testing.T) {
	for name, respond := range map[string]func(piMessageRequest, net.Conn){
		"malformed ack": func(_ piMessageRequest, conn net.Conn) { _, _ = conn.Write([]byte("not json\n")) },
		"extra ack field": func(request piMessageRequest, conn net.Conn) {
			_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"submitted","extra":true}` + "\n"))
		},
		"mismatched ack": func(request piMessageRequest, conn net.Conn) {
			_, _ = conn.Write([]byte(`{"id":"wrong","status":"submitted"}` + "\n"))
		},
		"rejected ack": func(request piMessageRequest, conn net.Conn) {
			_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"rejected"}` + "\n"))
		},
		"disconnect": func(piMessageRequest, net.Conn) {},
	} {
		t.Run(name, func(t *testing.T) {
			_, svc, sent, socketPath := newPiNativeService(t, respond)
			sessionID := filepath.Base(filepath.Dir(socketPath))
			if err := svc.Relay(t.Context(), sessionID, "hello"); err == nil {
				t.Fatal("relay succeeded, want terminal native error")
			}
			if len(*sent) != 0 {
				t.Fatalf("post-connect Pi error used tmux: %v", *sent)
			}
		})
	}

	t.Run("read deadline", func(t *testing.T) {
		_, svc, sent, socketPath := newPiNativeService(t, func(piMessageRequest, net.Conn) { time.Sleep(100 * time.Millisecond) })
		sessionID := filepath.Base(filepath.Dir(socketPath))
		ctx, cancel := context.WithTimeout(t.Context(), 10*time.Millisecond)
		defer cancel()
		if err := svc.Relay(ctx, sessionID, "hello"); err == nil {
			t.Fatal("relay succeeded, want read deadline")
		}
		if len(*sent) != 0 {
			t.Fatalf("Pi read deadline used tmux: %v", *sent)
		}
	})
}

func TestRelayFrom_PiNativeUsesLogicalProvenance(t *testing.T) {
	received := make(chan piMessageRequest, 1)
	_, svc, sent, socketPath := newPiNativeService(t, func(request piMessageRequest, conn net.Conn) {
		received <- request
		_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"submitted"}` + "\n"))
	})
	sessionID := filepath.Base(filepath.Dir(socketPath))
	if err := svc.RelayFrom(t.Context(), "qm-sender", sessionID, "hello"); err != nil {
		t.Fatalf("relay from: %v", err)
	}
	if len(*sent) != 0 {
		t.Fatalf("native Pi delivery used tmux: %v", *sent)
	}
	select {
	case request := <-received:
		if request.Message != "[FROM:qm-sender] hello" {
			t.Fatalf("Pi provenance = %q", request.Message)
		}
	case <-time.After(time.Second):
		t.Fatal("native Pi target did not receive provenance")
	}
}

func TestPiNativeUsesLogicalProvenanceForReportAndBroadcast(t *testing.T) {
	t.Run("report", func(t *testing.T) {
		received := make(chan piMessageRequest, 1)
		store, svc, sent, socketPath := newPiNativeService(t, func(request piMessageRequest, conn net.Conn) {
			received <- request
			_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"submitted"}` + "\n"))
		})
		masterID := filepath.Base(filepath.Dir(socketPath))
		if err := store.Update(masterID, func(m *state.Manifest) { m.SessionType = "master" }); err != nil {
			t.Fatalf("make Pi session a master: %v", err)
		}
		createWorkerManifest(t, store, "qm-pi-reporter", masterID)
		if err := svc.Report(t.Context(), "qm-pi-reporter", "finished"); err != nil {
			t.Fatalf("report: %v", err)
		}
		if len(*sent) != 0 {
			t.Fatalf("native Pi report used tmux: %v", *sent)
		}
		select {
		case got := <-received:
			if got.Message != "[WORKER:qm-pi-reporter] finished" {
				t.Fatalf("Pi report provenance = %q", got.Message)
			}
		case <-time.After(time.Second):
			t.Fatal("native Pi report target did not receive provenance")
		}
	})

	t.Run("broadcast", func(t *testing.T) {
		received := make(chan piMessageRequest, 1)
		store, svc, sent, socketPath := newPiNativeService(t, func(request piMessageRequest, conn net.Conn) {
			received <- request
			_, _ = conn.Write([]byte(`{"id":"` + request.ID + `","status":"submitted"}` + "\n"))
		})
		workerID := filepath.Base(filepath.Dir(socketPath))
		createManifest(t, store, "qm-pi-broadcast-master", "master", "master")
		if err := store.AddWorker("qm-pi-broadcast-master", workerID); err != nil {
			t.Fatalf("add Pi worker: %v", err)
		}
		result, err := svc.BroadcastFrom(t.Context(), "qm-sender", "qm-pi-broadcast-master", "hello")
		if err != nil {
			t.Fatalf("broadcast: %v", err)
		}
		if result.Delivered != 1 || len(*sent) != 0 {
			t.Fatalf("broadcast result=%+v tmux=%v", result, *sent)
		}
		select {
		case got := <-received:
			if got.Message != "[FROM:qm-sender] hello" {
				t.Fatalf("Pi broadcast provenance = %q", got.Message)
			}
		case <-time.After(time.Second):
			t.Fatal("native Pi broadcast target did not receive provenance")
		}
	})
}

func TestPiFrameRejectsOversizeMessage(t *testing.T) {
	if _, _, err := piFrame(strings.Repeat("x", piMaxFrameBytes+1)); err == nil {
		t.Fatal("oversize Pi message succeeded")
	}
}

func TestRelay_LargeMessage_UsesFileIndirection(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.Relay(t.Context(), "qm-w1", long)
	if err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if !strings.HasPrefix(sent[0], "Read and follow the instructions in ") {
		t.Fatalf("expected file pointer, got %q", sent[0])
	}
}

func TestRelayFrom_LargeMessage_PrefixesPointerAndFileContent(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.RelayFrom(t.Context(), "qm-master", "qm-w1", long)
	if err != nil {
		t.Fatalf("relay from: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if !strings.HasPrefix(sent[0], "[FROM:qm-master] Read and follow the instructions in ") {
		t.Fatalf("expected prefixed file pointer, got %q", sent[0])
	}

	path := relayFilePathFromPointer(t, sent[0])
	defer os.Remove(path)

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read relay file: %v", err)
	}
	if !strings.HasPrefix(string(content), "[FROM:qm-master] ") {
		t.Fatalf("expected file content provenance prefix, got %q", string(content))
	}
}

func TestRelay_SessionNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // not running
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Relay(t.Context(), "qm-w1", "hello")
	if err == nil {
		t.Fatal("expected error for non-running session")
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("expected 'not running' error, got: %v", err)
	}
}

func TestRelay_NoPaneFound(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "worker")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 codex", nil // no primary or claude role
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Relay(t.Context(), "qm-w1", "hello")
	if err == nil {
		t.Fatal("expected error when no primary pane found")
	}
}

func TestRelay_RejectsInvalidWorkerID(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		t.Fatalf("relay should reject invalid worker id before tmux call: %v", args)
		return "", nil
	}}
	svc := newService(store, runner)

	err := svc.Relay(t.Context(), "../qm-w1", "hello")
	if err == nil || !strings.Contains(err.Error(), "invalid worker id") {
		t.Fatalf("relay error = %v, want invalid worker id", err)
	}
}

func TestRelay_RejectsMissingManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		t.Fatalf("relay should reject missing manifest before tmux call: %v", args)
		return "", nil
	}}
	svc := newService(store, runner)

	err := svc.Relay(t.Context(), "qm-missing", "hello")
	if err == nil || !strings.Contains(err.Error(), "read worker manifest") {
		t.Fatalf("relay error = %v, want missing manifest", err)
	}
}

func TestAgentOnlyCommandsRejectPlainTerminalSessions(t *testing.T) {
	t.Parallel()

	tests := map[string]func(*testing.T, *state.Store, *Service) error{
		"relay": func(t *testing.T, store *state.Store, svc *Service) error {
			t.Helper()
			createPlainManifest(t, store, "qm-plain", "plain")
			return svc.Relay(t.Context(), "qm-plain", "hello")
		},
		"broadcast": func(t *testing.T, store *state.Store, svc *Service) error {
			t.Helper()
			createPlainManifest(t, store, "qm-plain", "plain")
			_, err := svc.Broadcast(t.Context(), "qm-plain", "hello")
			return err
		},
		"report": func(t *testing.T, store *state.Store, svc *Service) error {
			t.Helper()
			createPlainManifest(t, store, "qm-plain-master", "plain master")
			createWorkerManifest(t, store, "qm-worker", "qm-plain-master")
			return svc.Report(t.Context(), "qm-worker", "done")
		},
	}

	for name, run := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			store := setupStore(t)
			svc := newService(store, idleAndSendRunner(new([]string)))

			err := run(t, store, svc)
			if err == nil || !strings.Contains(err.Error(), "has no agent (plain terminal session)") {
				t.Fatalf("%s error = %v, want plain terminal guard", name, err)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Broadcast tests
// ---------------------------------------------------------------------------

func TestBroadcast_SendsToAllWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	result, err := svc.Broadcast(t.Context(), "qm-master", "hello all")
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 2 {
		t.Fatalf("expected 2 sends, got %d", result.Delivered)
	}
}

func TestBroadcastFrom_PrefixesDeliveredText(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	result, err := svc.BroadcastFrom(t.Context(), "qm-master", "qm-master", "hello all")
	if err != nil {
		t.Fatalf("broadcast from: %v", err)
	}
	if result.Delivered != 2 {
		t.Fatalf("expected 2 sends, got %d", result.Delivered)
	}
	for _, msg := range sent {
		if msg != "[FROM:qm-master] hello all" {
			t.Fatalf("expected prefixed broadcast message, got %q", msg)
		}
	}
}

func TestBroadcastFrom_RejectsInvalidSender(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	svc := newService(store, idleAndSendRunner(new([]string)))

	if _, err := svc.BroadcastFrom(t.Context(), "not-a-session", "qm-master", "hello"); err == nil {
		t.Fatal("broadcast accepted invalid sender")
	}
}

func TestBroadcastFrom_ClaudeNativeUsesLogicalProvenance(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	pid := os.Getpid()
	canonical := "qm-w1:@0.%1"
	received := claudeNativeSocket(t, pid, canonical)
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))
	message := strings.Repeat("x", LargeMessageThreshold+1)
	result, err := svc.BroadcastFrom(t.Context(), "qm-master", "qm-master", message)
	if err != nil {
		t.Fatalf("broadcast from: %v", err)
	}
	if result.Delivered != 1 || len(sent) != 0 {
		t.Fatalf("broadcast result=%+v tmux=%v, want native-only delivery", result, sent)
	}
	select {
	case data := <-received:
		var frame struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatalf("decode native frame: %v", err)
		}
		want := `<cross-session-message from-name="Questmaster">` + "\n[FROM:qm-master] " + message + "\n</cross-session-message>"
		if frame.Message.Content != want {
			t.Fatalf("native content = %q, want logical provenance without a file pointer", frame.Message.Content)
		}
	case <-time.After(time.Second):
		t.Fatal("native broadcast target did not receive a frame")
	}
}

func TestBroadcast_MixesNativeAndTmuxDelivery(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")
	setPrimaryAgent(t, store, "qm-w2", "codex")

	pid := os.Getpid()
	canonical := "qm-w1:@0.%1"
	received := claudeNativeSocket(t, pid, canonical)
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))
	result, err := svc.Broadcast(t.Context(), "qm-master", "hello all")
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 2 || len(sent) != 1 || sent[0] != "hello all" {
		t.Fatalf("broadcast result=%+v tmux=%v", result, sent)
	}
	select {
	case <-received:
	case <-time.After(time.Second):
		t.Fatal("native broadcast target did not receive a frame")
	}
}

func TestBroadcast_OpenCodeNativePIDMismatchDoesNotFallback(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	setPrimaryAgent(t, store, "qm-w1", "opencode")
	writeOpenCodeNativeStateAt(t, store.Root(), "qm-w1", state.PaneState{
		Role: primaryRole, Agent: "opencode", State: "idle", OpenCodePID: os.Getpid() + 1,
	})

	var sent []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch args[0] {
		case "has-session":
			return "", nil
		case "list-panes":
			return "0 0 primary", nil
		case "display-message":
			return strconv.Itoa(os.Getpid()) + "\tqm-w1:@0.%1", nil
		case "send-keys":
			sent = append(sent, "unexpected")
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	result, err := newService(store, runner).Broadcast(t.Context(), "qm-master", "hello")
	if err == nil || !strings.Contains(err.Error(), "does not match hook pid") {
		t.Fatalf("broadcast error = %v, want pane generation mismatch", err)
	}
	if result.Registered != 1 || result.Delivered != 0 {
		t.Fatalf("broadcast result = %+v, want registered 1 and delivered 0", result)
	}
	if len(sent) != 0 {
		t.Fatalf("pane generation mismatch used tmux: %v", sent)
	}
}

func TestBroadcast_TmuxFallbackReusesOneLargeMessagePointer(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")
	setPrimaryAgent(t, store, "qm-w1", "codex")
	setPrimaryAgent(t, store, "qm-w2", "codex")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	result, err := svc.Broadcast(t.Context(), "qm-master", strings.Repeat("x", LargeMessageThreshold+1))
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 2 || len(sent) != 2 || sent[0] != sent[1] {
		t.Fatalf("broadcast result=%+v tmux=%v, want shared pointer", result, sent)
	}
}

func TestBroadcast_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")

	svc := newService(store, idleAndSendRunner(new([]string)))
	result, err := svc.Broadcast(t.Context(), "qm-master", "hello")
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Registered != 0 {
		t.Fatalf("expected 0 registered, got %d", result.Registered)
	}
}

func TestBroadcast_SkipsDeadWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	// w1 alive, w2 dead
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if target == "qm-w2" {
				return "", &tmux.ExitError{Code: 1}
			}
			return "", nil
		}
		if len(args) >= 1 && args[0] == "display-message" {
			if args[len(args)-1] == "#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}" {
				return "999999\t" + args[2], nil
			}
			return "0", nil
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	result, err := svc.Broadcast(t.Context(), "qm-master", "hello")
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 1 {
		t.Fatalf("expected 1 send (skipping dead worker), got %d", result.Delivered)
	}
	if result.Registered != 2 {
		t.Fatalf("expected 2 registered, got %d", result.Registered)
	}
}

func TestBroadcast_LargeMessage_UsesFileIndirection(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	result, err := svc.Broadcast(t.Context(), "qm-master", long)
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 1 {
		t.Fatalf("expected 1 send, got %d", result.Delivered)
	}
	if len(sent) == 0 || !strings.HasPrefix(sent[0], "Read and follow the instructions in ") {
		t.Fatalf("expected file pointer for large message, got %v", sent)
	}
}

// Regression: a broadcast to a LIVE, registered worker whose Send fails must
// surface an error. Previously the per-worker Send error was swallowed (Delivered
// only incremented on success, transportErr only set on HasSession errors), so a
// zero-delivery broadcast returned (Delivered:0, err:nil) — silent, exactly the
// reported TUI symptom.
func TestBroadcast_LiveWorkerSendFailureIsSurfaced(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch {
		case len(args) >= 1 && args[0] == "has-session":
			return "", nil // worker is alive
		case len(args) >= 1 && args[0] == "list-panes":
			return "1 0 primary", nil // primary pane resolves
		case len(args) >= 1 && args[0] == "display-message":
			return "0", nil // pane idle
		case len(args) >= 1 && args[0] == "send-keys":
			return "", &tmux.ExitError{Code: 1} // delivery fails
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)

	result, err := svc.Broadcast(t.Context(), "qm-master", "hello")
	if result.Delivered != 0 {
		t.Fatalf("expected 0 delivered when send fails, got %d", result.Delivered)
	}
	if err == nil {
		t.Fatal("broadcast to a live worker whose send failed must surface an error, not silently report zero delivery")
	}
}

// Regression: a live worker whose primary pane cannot be resolved must surface an
// error. Previously ResolveRole failures were silently `continue`d.
func TestBroadcast_LiveWorkerResolveFailureIsSurfaced(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		switch {
		case len(args) >= 1 && args[0] == "has-session":
			return "", nil // worker is alive
		case len(args) >= 1 && args[0] == "list-panes":
			return "1 0 shell", nil // no primary pane → ResolveRole fails
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)

	result, err := svc.Broadcast(t.Context(), "qm-master", "hello")
	if result.Delivered != 0 {
		t.Fatalf("expected 0 delivered when pane resolution fails, got %d", result.Delivered)
	}
	if err == nil {
		t.Fatal("broadcast to a live worker whose primary pane cannot be resolved must surface an error")
	}
}

// ---------------------------------------------------------------------------
// Read tests
// ---------------------------------------------------------------------------

func TestRead_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "⏺ Bash(npx openspec new 2>&1)\n⎿ Error: Exit code 1\n   npm error could not determine executable\n\nsome noise\n⏺ Edited file.go\n⎿ Done\n❯ done", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), "qm-w1", 50)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "⏺ Bash(npx openspec new 2>&1)\n⎿ Error: Exit code 1\nnpm error could not determine executable\n⏺ Edited file.go\n⎿ Done"
	if output != want {
		t.Fatalf("expected filtered output %q, got %q", want, output)
	}
}

func TestRead_CodexWorkerUsesWizardFilter(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "")
	setPrimaryAgent(t, store, "qm-w1", "codex")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "• I shall inspect the file.\n⏺ Ran rg foo\n⎿ found it\n", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), "qm-w1", 50)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "• I shall inspect the file.\n⏺ Ran rg foo\n⎿ found it"
	if output != want {
		t.Fatalf("expected wizard-filtered output %q, got %q", want, output)
	}
}

func TestReadPlainTerminalCapturesWorkspacePaneRaw(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-plain-read"
	createPlainManifest(t, store, sessionID, "plain")

	var captureTarget string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			t.Fatalf("plain read should capture pane 0 directly, not resolve roles")
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			captureTarget = flagValue(args, "-t")
			return "\nfirst\n\n  second  \nthird\n", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)

	output, err := svc.Read(t.Context(), sessionID, 2)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if captureTarget != sessionID+":0.0" {
		t.Fatalf("capture target = %q, want workspace pane 0", captureTarget)
	}
	if output != "second\nthird" {
		t.Fatalf("plain read output = %q, want trimmed tail", output)
	}
}

func TestRead_PiUsesActivitySidecarWithoutCapture(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-pi-read-sidecar"
	createManifest(t, store, sessionID, "pi worker", "")
	setPrimaryAgent(t, store, sessionID, "pi")
	writePiActivityState(t, sessionID, piActivityFixture{
		State:     "working",
		LastEvent: time.Now().Add(-time.Hour), // stale is still usable for read output
		Activity:  "fallback snippet",
		Recent:    []string{"one", "two", "three", "four"},
	})

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && (args[0] == "list-panes" || args[0] == "capture-pane") {
			t.Fatalf("Pi sidecar read should not call tmux %s", args[0])
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), sessionID, 2)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "three\nfour"
	if output != want {
		t.Fatalf("expected sidecar recent tail %q, got %q", want, output)
	}
}

func TestRead_OpenCodeUsesHookActivityWithoutCapture(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-opencode-read-hook"
	createManifest(t, store, sessionID, "opencode worker", "")
	setPrimaryAgent(t, store, sessionID, "opencode")
	writeOpenCodeActivityState(t, sessionID, []string{"alpha", "beta", "gamma"}, "fallback")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && (args[0] == "list-panes" || args[0] == "capture-pane") {
			t.Fatalf("OpenCode hook read should not call tmux %s", args[0])
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), sessionID, 2)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if output != "beta\ngamma" {
		t.Fatalf("read output = %q, want beta/gamma tail", output)
	}
}

func TestRead_PiFallsBackToRawCaptureWhenSidecarMissing(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	sessionID := "qm-pi-read-raw"
	createManifest(t, store, sessionID, "pi worker", "")
	setPrimaryAgent(t, store, sessionID, "pi")
	removePiActivitySidecar(t, sessionID)

	var captureArgs []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			captureArgs = args
			return "\x1b[32mfirst raw line\x1b[0m\n\n  second raw line  \nthird raw line\n", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), sessionID, 2)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "[raw Pi pane output — no usable activity sidecar]\nsecond raw line\nthird raw line"
	if output != want {
		t.Fatalf("expected raw Pi fallback %q, got %q", want, output)
	}
	found := false
	for _, arg := range captureArgs {
		if arg == "-2" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected -2 in capture args, got %v", captureArgs)
	}
}

func TestRead_NonPiFilteringUnchanged(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name  string
		agent string
		raw   string
		want  string
	}{
		{
			name:  "claude",
			agent: "claude",
			raw:   "plain pane text\n⏺ Claude tool\n⎿ Claude result\n❯ user prompt\n• Codex-only note\n",
			want:  "⏺ Claude tool\n⎿ Claude result",
		},
		{
			name:  "codex",
			agent: "codex",
			raw:   "plain pane text\n• Codex note\n⏺ Codex tool\n⎿ Codex result\n",
			want:  "• Codex note\n⏺ Codex tool\n⎿ Codex result",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := setupStore(t)
			sessionID := "qm-read-filter-" + tc.name
			createManifest(t, store, sessionID, tc.name+" worker", "")
			setPrimaryAgent(t, store, sessionID, tc.agent)

			runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
				if len(args) >= 1 && args[0] == "has-session" {
					return "", nil
				}
				if len(args) >= 1 && args[0] == "list-panes" {
					return "1 0 primary", nil
				}
				if len(args) >= 1 && args[0] == "capture-pane" {
					return tc.raw, nil
				}
				return "", &tmux.ExitError{Code: 1}
			}}
			svc := newService(store, runner)
			output, err := svc.Read(t.Context(), sessionID, 50)
			if err != nil {
				t.Fatalf("read: %v", err)
			}
			if output != tc.want {
				t.Fatalf("expected %s filtered output %q, got %q", tc.agent, tc.want, output)
			}
		})
	}
}

func TestRead_CustomLineCount(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "")

	var captureArgs []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 primary", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			captureArgs = args
			return "⏺ output", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	_, err := svc.Read(t.Context(), "qm-w1", 200)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// Verify -S -200 was passed
	found := false
	for _, a := range captureArgs {
		if a == "-200" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected -200 in capture args, got %v", captureArgs)
	}
}

func TestRead_SessionNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	_, err := svc.Read(t.Context(), "qm-w1", 50)
	if err == nil {
		t.Fatal("expected error for non-running session")
	}
}

// ---------------------------------------------------------------------------
// Report tests
// ---------------------------------------------------------------------------

func TestReport_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.Report(t.Context(), "qm-w1", "done: fixed the bug")
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	expected := "[WORKER:qm-w1] done: fixed the bug"
	if sent[0] != expected {
		t.Fatalf("expected %q, got %q", expected, sent[0])
	}
}

func TestReport_ClaudeNativeUsesLogicalProvenance(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	pid := os.Getpid()
	canonical := "qm-master:@0.%1"
	received := claudeNativeSocket(t, pid, canonical)
	var sent []string
	svc := newService(store, claudeNativeRunner(pid, canonical, &sent))
	message := strings.Repeat("x", LargeMessageThreshold+1)
	if err := svc.Report(t.Context(), "qm-w1", message); err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) != 0 {
		t.Fatalf("report used tmux fallback: %v", sent)
	}
	select {
	case data := <-received:
		var frame struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatalf("decode native frame: %v", err)
		}
		want := `<cross-session-message from-name="Questmaster">` + "\n[WORKER:qm-w1] " + message + "\n</cross-session-message>"
		if frame.Message.Content != want {
			t.Fatalf("native content = %q, want logical provenance without a file pointer", frame.Message.Content)
		}
	case <-time.After(time.Second):
		t.Fatal("native report did not reach Claude socket")
	}
}

func TestReport_NoParentSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-solo", "solo", "")

	svc := newService(store, idleAndSendRunner(new([]string)))
	err := svc.Report(t.Context(), "qm-solo", "done")
	if err == nil {
		t.Fatal("expected error for session without parent")
	}
	if !strings.Contains(err.Error(), "parent") {
		t.Fatalf("expected parent-related error, got: %v", err)
	}
}

func TestReport_MasterNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // master not running
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Report(t.Context(), "qm-w1", "done")
	if err == nil {
		t.Fatal("expected error when master is not running")
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("expected 'not running' error, got: %v", err)
	}
}

func TestReport_LargeMessage_UsesFileIndirection(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.Report(t.Context(), "qm-w1", long)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if !strings.HasPrefix(sent[0], "[WORKER:qm-w1] ") {
		t.Fatalf("expected [WORKER:] prefix, got %q", sent[0])
	}
	if strings.Contains(sent[0], "Act on them") || strings.Contains(sent[0], "follow the instructions") {
		t.Fatalf("worker-report pointer must not be imperative, got %q", sent[0])
	}
	if !strings.Contains(sent[0], "qm-relay-") {
		t.Fatalf("expected pointer to the relay file, got %q", sent[0])
	}
}

// ---------------------------------------------------------------------------
// B2: Report file content must include worker prefix
// ---------------------------------------------------------------------------

func TestReport_LargeMessage_FileContentIncludesPrefix(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.Report(t.Context(), "qm-w1", long)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}

	// Extract file path from pointer message. The pointer reads:
	// "[WORKER:qm-w1] Worker report available at <path>. Read it to see the results."
	const marker = " at "
	idx := strings.Index(sent[0], marker)
	if idx < 0 {
		t.Fatalf("could not locate relay path marker in pointer: %q", sent[0])
	}
	tail := sent[0][idx+len(marker):]
	end := strings.Index(tail, ".md")
	if end < 0 {
		t.Fatalf("could not locate relay path end in pointer: %q", sent[0])
	}
	path := tail[:end+3]
	defer os.Remove(path)

	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read relay file: %v", err)
	}

	// The file content must include the worker prefix so the receiver knows the sender.
	if !strings.Contains(string(content), "[WORKER:qm-w1]") {
		t.Errorf("relay file must contain worker prefix, got: %s", string(content)[:min(100, len(content))])
	}
}

// ---------------------------------------------------------------------------
// Workers tests
// ---------------------------------------------------------------------------

// W1: Workers() collapses all HasSession errors to status "stopped".
// Transient tmux failures (socket timeout, permission denied) should not be
// silently reported as "stopped" — that triggers ghost-pruning of workers
// that are actually running.
func TestWorkers_TmuxErrorNotMaskedAsStopped(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	// HasSession returns an ExitError with connection-error stderr,
	// matching real tmux behavior (e.g. dead socket).
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-501/default (Permission denied)"}
		}
		return "", nil
	}}

	svc := newService(store, runner)

	workers, err := svc.Workers(t.Context(), "qm-master")

	// After fix: either returns an error OR uses a status other than "stopped".
	if err != nil {
		return // propagating the error is one valid fix
	}

	for _, w := range workers {
		if w.SessionID == "qm-w1" && w.Status == "stopped" {
			t.Error("tmux transport error should not be reported as 'stopped'; " +
				"should be 'error' or Workers() should return an error")
		}
	}
}

// W1: Broadcast() silently skips workers on tmux transport errors.
// A transport error (connection refused, socket timeout) is different from
// "session not found" — it should be surfaced, not silently swallowed.
func TestBroadcast_TmuxTransportError(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1, Stderr: "error connecting to /tmp/tmux-501/default (Permission denied)"}
		}
		return "", nil
	}}

	svc := newService(store, runner)

	_, err := svc.Broadcast(t.Context(), "qm-master", "hello")
	if err == nil {
		t.Error("Broadcast should propagate tmux transport errors, not silently skip workers")
	}
}

func TestWorkers_ReturnsAllWithStatus(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")

	// w1 alive, w2 dead
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if target == "qm-w2" {
				return "", &tmux.ExitError{Code: 1}
			}
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "qm-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}
	if len(workers) != 2 {
		t.Fatalf("expected 2 workers, got %d", len(workers))
	}

	statusMap := make(map[string]string)
	for _, w := range workers {
		statusMap[w.SessionID] = w.Status
	}
	if statusMap["qm-w1"] != "active" {
		t.Fatalf("expected qm-w1 active, got %q", statusMap["qm-w1"])
	}
	if statusMap["qm-w2"] != "stopped" {
		t.Fatalf("expected qm-w2 stopped, got %q", statusMap["qm-w2"])
	}
}

func TestWorkers_UsesHookDerivedPaneState(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-status-master", "master", "master")

	createWorkerManifest(t, store, "qm-status-working", "qm-status-master")
	createWorkerManifest(t, store, "qm-status-idle", "qm-status-master")
	createWorkerManifest(t, store, "qm-status-hookless", "qm-status-master")
	createWorkerManifest(t, store, "qm-status-dead", "qm-status-master")

	writePrimaryPaneState(t, "qm-status-working", "working")
	writePrimaryPaneState(t, "qm-status-idle", "idle")
	writePrimaryPaneState(t, "qm-status-dead", "working")

	live := map[string]bool{
		"qm-status-working":  true,
		"qm-status-idle":     true,
		"qm-status-hookless": true,
	}
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if live[target] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "qm-status-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}

	statusByID := make(map[string]string)
	for _, w := range workers {
		statusByID[w.SessionID] = w.Status
	}
	want := map[string]string{
		"qm-status-working":  "working",
		"qm-status-idle":     "idle",
		"qm-status-hookless": "active",
		"qm-status-dead":     "stopped",
	}
	for id, expected := range want {
		if statusByID[id] != expected {
			t.Fatalf("%s status = %q, want %q", id, statusByID[id], expected)
		}
	}
}

func TestWorkers_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")

	svc := newService(store, idleAndSendRunner(new([]string)))
	workers, err := svc.Workers(t.Context(), "qm-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}
	if len(workers) != 0 {
		t.Fatalf("expected 0 workers, got %d", len(workers))
	}
}

func TestWorkers_AutoPrunesGhostEntries(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	// qm-w2 is in master's Workers list but has NO manifest (simulating prune)
	if err := store.AddWorker("qm-master", "qm-w2"); err != nil {
		t.Fatalf("add ghost worker: %v", err)
	}

	// Both workers dead (no tmux sessions)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1}
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "qm-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}

	// qm-w2 (no manifest + no tmux) should be auto-pruned from the list
	for _, w := range workers {
		if w.SessionID == "qm-w2" {
			t.Fatal("ghost worker qm-w2 (no manifest, no tmux) should have been auto-pruned")
		}
	}

	// Verify qm-w2 was removed from master's Workers list on disk
	remaining, err := store.GetWorkers("qm-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	for _, id := range remaining {
		if id == "qm-w2" {
			t.Fatal("ghost worker qm-w2 should have been removed from master's Workers list")
		}
	}
}

func TestWorkers_IncludesTitles(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "master")

	// Create worker with title
	m := state.Manifest{
		SessionID: "qm-w1",
		Title:     "Fix auth bug",
		Cwd:       "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"qm-master"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := store.AddWorker("qm-master", "qm-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "qm-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}
	if len(workers) != 1 {
		t.Fatalf("expected 1 worker, got %d", len(workers))
	}
	if workers[0].Title != "Fix auth bug" {
		t.Fatalf("expected title 'Fix auth bug', got %q", workers[0].Title)
	}
}
