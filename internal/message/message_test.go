//go:build linux || darwin

package message

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

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
		PartyID:     id,
		Title:       title,
		Cwd:         "/tmp",
		SessionType: sessionType,
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest %s: %v", id, err)
	}
}

func createWorkerManifest(t *testing.T, store *state.Store, id, parentID string) {
	t.Helper()
	m := state.Manifest{
		PartyID: id,
		Cwd:     "/tmp",
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

// idleAndSendRunner returns a runner that reports panes as idle
// and records send-keys calls.
func idleAndSendRunner(sent *[]string) *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "display-message" {
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
			return "1 0 claude", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
}

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
	if !strings.HasPrefix(pointer, "Read relay instructions at ") {
		t.Fatalf("expected pointer prefix, got %q", pointer)
	}
	if !strings.Contains(pointer, path) {
		t.Fatalf("expected path in pointer, got %q", pointer)
	}
}

// ---------------------------------------------------------------------------
// Relay tests
// ---------------------------------------------------------------------------

func TestRelay_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.Relay(t.Context(), "party-w1", "hello worker")
	if err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if sent[0] != "[MASTER] hello worker" {
		t.Fatalf("expected '[MASTER] hello worker', got %q", sent[0])
	}
}

func TestRelay_LargeMessage_UsesFileIndirection(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.Relay(t.Context(), "party-w1", long)
	if err != nil {
		t.Fatalf("relay: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if !strings.HasPrefix(sent[0], "Read relay instructions at ") {
		t.Fatalf("expected file pointer, got %q", sent[0])
	}
}

func TestRelay_SessionNotRunning(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // not running
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Relay(t.Context(), "party-w1", "hello")
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
	createManifest(t, store, "party-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 codex", nil // no claude role
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Relay(t.Context(), "party-w1", "hello")
	if err == nil {
		t.Fatal("expected error when no Claude pane found")
	}
}

// ---------------------------------------------------------------------------
// Broadcast tests
// ---------------------------------------------------------------------------

func TestBroadcast_SendsToAllWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")
	createWorkerManifest(t, store, "party-w2", "party-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	result, err := svc.Broadcast(t.Context(), "party-master", "hello all")
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 2 {
		t.Fatalf("expected 2 sends, got %d", result.Delivered)
	}
}

func TestBroadcast_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "master")

	svc := newService(store, idleAndSendRunner(new([]string)))
	result, err := svc.Broadcast(t.Context(), "party-master", "hello")
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
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")
	createWorkerManifest(t, store, "party-w2", "party-master")

	// w1 alive, w2 dead
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if target == "party-w2" {
				return "", &tmux.ExitError{Code: 1}
			}
			return "", nil
		}
		if len(args) >= 1 && args[0] == "display-message" {
			return "0", nil
		}
		if len(args) >= 1 && args[0] == "send-keys" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	result, err := svc.Broadcast(t.Context(), "party-master", "hello")
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
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	result, err := svc.Broadcast(t.Context(), "party-master", long)
	if err != nil {
		t.Fatalf("broadcast: %v", err)
	}
	if result.Delivered != 1 {
		t.Fatalf("expected 1 send, got %d", result.Delivered)
	}
	if len(sent) == 0 || !strings.HasPrefix(sent[0], "Read relay instructions at ") {
		t.Fatalf("expected file pointer for large message, got %v", sent)
	}
}

// ---------------------------------------------------------------------------
// Read tests
// ---------------------------------------------------------------------------

func TestRead_Success(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			return "line1\nline2\nline3", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	output, err := svc.Read(t.Context(), "party-w1", 50)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if output != "line1\nline2\nline3" {
		t.Fatalf("expected captured output, got %q", output)
	}
}

func TestRead_CustomLineCount(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-w1", "worker1", "")

	var captureArgs []string
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		if len(args) >= 1 && args[0] == "list-panes" {
			return "1 0 claude", nil
		}
		if len(args) >= 1 && args[0] == "capture-pane" {
			captureArgs = args
			return "output", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	_, err := svc.Read(t.Context(), "party-w1", 200)
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
	createManifest(t, store, "party-w1", "worker1", "")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	_, err := svc.Read(t.Context(), "party-w1", 50)
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
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	err := svc.Report(t.Context(), "party-w1", "done: fixed the bug")
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	expected := "[WORKER:party-w1] done: fixed the bug"
	if sent[0] != expected {
		t.Fatalf("expected %q, got %q", expected, sent[0])
	}
}

func TestReport_NoParentSession(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-solo", "solo", "")

	svc := newService(store, idleAndSendRunner(new([]string)))
	err := svc.Report(t.Context(), "party-solo", "done")
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
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // master not running
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	err := svc.Report(t.Context(), "party-w1", "done")
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
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")

	var sent []string
	svc := newService(store, idleAndSendRunner(&sent))
	long := strings.Repeat("x", LargeMessageThreshold+1)
	err := svc.Report(t.Context(), "party-w1", long)
	if err != nil {
		t.Fatalf("report: %v", err)
	}
	if len(sent) == 0 {
		t.Fatal("expected send-keys call")
	}
	if !strings.HasPrefix(sent[0], "[WORKER:party-w1] Read relay instructions at ") {
		t.Fatalf("expected [WORKER:] prefix with file pointer, got %q", sent[0])
	}
}

// ---------------------------------------------------------------------------
// Workers tests
// ---------------------------------------------------------------------------

func TestWorkers_ReturnsAllWithStatus(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "master")
	createWorkerManifest(t, store, "party-w1", "party-master")
	createWorkerManifest(t, store, "party-w2", "party-master")

	// w1 alive, w2 dead
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			target := args[len(args)-1]
			if target == "party-w2" {
				return "", &tmux.ExitError{Code: 1}
			}
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "party-master")
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
	if statusMap["party-w1"] != "active" {
		t.Fatalf("expected party-w1 active, got %q", statusMap["party-w1"])
	}
	if statusMap["party-w2"] != "stopped" {
		t.Fatalf("expected party-w2 stopped, got %q", statusMap["party-w2"])
	}
}

func TestWorkers_NoWorkers(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "master")

	svc := newService(store, idleAndSendRunner(new([]string)))
	workers, err := svc.Workers(t.Context(), "party-master")
	if err != nil {
		t.Fatalf("workers: %v", err)
	}
	if len(workers) != 0 {
		t.Fatalf("expected 0 workers, got %d", len(workers))
	}
}

func TestWorkers_IncludesTitles(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master", "master")

	// Create worker with title
	m := state.Manifest{
		PartyID: "party-w1",
		Title:   "Fix auth bug",
		Cwd:     "/tmp",
		Extra: map[string]json.RawMessage{
			"parent_session": json.RawMessage(`"party-master"`),
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := store.AddWorker("party-master", "party-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "has-session" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}
	svc := newService(store, runner)
	workers, err := svc.Workers(t.Context(), "party-master")
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
