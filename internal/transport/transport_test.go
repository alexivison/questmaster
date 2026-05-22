//go:build linux || darwin

package transport

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

type mockRunner struct {
	fn func(ctx context.Context, args ...string) (string, error)
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	return m.fn(ctx, args...)
}

type sentMessage struct {
	target string
	text   string
}

type envSet struct {
	session string
	key     string
	value   string
}

type transportFixture struct {
	sessionID     string
	currentRole   string
	currentWindow int
	panes         []tmux.Pane
	sent          []sentMessage
	env           []envSet
	sendErr       error
	setEnvErr     error
}

func newTransportFixture(sessionID, role string) *transportFixture {
	return &transportFixture{
		sessionID:     sessionID,
		currentRole:   role,
		currentWindow: 1,
		panes: []tmux.Pane{
			{SessionName: sessionID, WindowIndex: 0, PaneIndex: 0, Role: tmux.RoleCompanion},
			{SessionName: sessionID, WindowIndex: 1, PaneIndex: 0, Role: tmux.RolePrimary},
		},
	}
}

func (f *transportFixture) runner() *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) == 0 {
			return "", fmt.Errorf("missing tmux args")
		}
		switch args[0] {
		case "display-message":
			format := args[len(args)-1]
			switch format {
			case "#{session_name}":
				return f.sessionID, nil
			case "#{session_name}\t#{window_index}\t#{pane_index}\t#{@party_role}":
				return fmt.Sprintf("%s\t%d\t0\t%s", f.sessionID, f.currentWindow, f.currentRole), nil
			case "#{pane_in_mode}":
				return "0", nil
			default:
				return "", fmt.Errorf("unexpected display-message format %q", format)
			}
		case "list-panes":
			lines := make([]string, 0, len(f.panes))
			for _, pane := range f.panes {
				lines = append(lines, fmt.Sprintf("%d %d %s", pane.WindowIndex, pane.PaneIndex, pane.Role))
			}
			return strings.Join(lines, "\n"), nil
		case "send-keys":
			if f.sendErr != nil {
				return "", f.sendErr
			}
			target := ""
			for i, arg := range args {
				if arg == "-t" && i+1 < len(args) {
					target = args[i+1]
				}
				if arg == "-l" && i+2 < len(args) {
					f.sent = append(f.sent, sentMessage{target: target, text: args[i+2]})
				}
			}
			return "", nil
		case "set-environment":
			if f.setEnvErr != nil {
				return "", f.setEnvErr
			}
			if len(args) != 5 {
				return "", fmt.Errorf("unexpected set-environment args: %v", args)
			}
			f.env = append(f.env, envSet{session: args[2], key: args[3], value: args[4]})
			return "", nil
		default:
			return "", fmt.Errorf("unexpected tmux command: %v", args)
		}
	}}
}

func setupStore(t *testing.T) *state.Store {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return store
}

func createManifest(t *testing.T, store *state.Store, id, sessionType string) {
	t.Helper()
	if err := store.Create(state.Manifest{PartyID: id, Cwd: "/tmp", SessionType: sessionType}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
}

func readCodexThreadID(t *testing.T, store *state.Store, sessionID string) string {
	t.Helper()
	m, err := store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	return m.ExtraString("codex_thread_id")
}

type failingUpdateStore struct {
	*state.Store
}

func (s failingUpdateStore) Update(string, func(*state.Manifest)) error {
	return errors.New("write failed")
}

type updateCountingStore struct {
	*state.Store
	updates int
}

func (s *updateCountingStore) Update(partyID string, fn func(*state.Manifest)) error {
	s.updates++
	return s.Store.Update(partyID, fn)
}

func TestDeliverPrimaryToCompanionPrefixesAndLeavesManifestAlone(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	fixture := newTransportFixture("party-transport", tmux.RolePrimary)

	result, err := NewService(store, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "hello")
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if result.TargetRole != tmux.RoleCompanion {
		t.Fatalf("target role: got %q, want companion", result.TargetRole)
	}
	if len(fixture.sent) != 1 {
		t.Fatalf("sent calls: got %d, want 1", len(fixture.sent))
	}
	if got, want := fixture.sent[0].target, "party-transport:0.0"; got != want {
		t.Fatalf("target: got %q, want %q", got, want)
	}
	if got, want := fixture.sent[0].text, "[PRIMARY] hello"; got != want {
		t.Fatalf("message: got %q, want %q", got, want)
	}
	if got := readCodexThreadID(t, store, "party-transport"); got != "" {
		t.Fatalf("codex_thread_id changed: %q", got)
	}
	if len(fixture.env) != 0 {
		t.Fatalf("set-environment calls: got %+v, want none", fixture.env)
	}
}

func TestDeliverCompanionToPrimaryCapturesCodexThreadID(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	fixture := newTransportFixture("party-transport", tmux.RoleCompanion)
	fixture.currentWindow = 0
	t.Setenv("CODEX_THREAD_ID", "thread-123")

	_, err := NewService(store, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "done")
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if got := readCodexThreadID(t, store, "party-transport"); got != "thread-123" {
		t.Fatalf("codex_thread_id: got %q, want thread-123", got)
	}
	if len(fixture.env) != 1 {
		t.Fatalf("set-environment calls: got %d, want 1", len(fixture.env))
	}
	if got := fixture.env[0]; got != (envSet{session: "party-transport", key: "CODEX_THREAD_ID", value: "thread-123"}) {
		t.Fatalf("set-environment: got %+v", got)
	}
	if got, want := fixture.sent[0].text, "[COMPANION] done"; got != want {
		t.Fatalf("message: got %q, want %q", got, want)
	}
}

func TestDeliverCompanionToPrimaryDoesNotOverwriteExistingCodexThreadID(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	if err := store.Update("party-transport", func(m *state.Manifest) {
		m.SetExtra("codex_thread_id", "original-thread")
	}); err != nil {
		t.Fatalf("seed manifest: %v", err)
	}
	fixture := newTransportFixture("party-transport", tmux.RoleCompanion)
	fixture.currentWindow = 0
	t.Setenv("CODEX_THREAD_ID", "new-thread")
	countingStore := &updateCountingStore{Store: store}

	_, err := NewService(countingStore, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "done")
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if got := readCodexThreadID(t, store, "party-transport"); got != "original-thread" {
		t.Fatalf("codex_thread_id: got %q, want original-thread", got)
	}
	if countingStore.updates != 0 {
		t.Fatalf("manifest updates: got %d, want 0", countingStore.updates)
	}
	if len(fixture.env) != 0 {
		t.Fatalf("set-environment calls: got %+v, want none", fixture.env)
	}
}

func TestDeliverCompanionToPrimaryWithoutCodexThreadIDStillDelivers(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	fixture := newTransportFixture("party-transport", tmux.RoleCompanion)
	fixture.currentWindow = 0
	t.Setenv("CODEX_THREAD_ID", "")
	countingStore := &updateCountingStore{Store: store}

	_, err := NewService(countingStore, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "done")
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if len(fixture.sent) != 1 {
		t.Fatalf("sent calls: got %d, want 1", len(fixture.sent))
	}
	if got := readCodexThreadID(t, store, "party-transport"); got != "" {
		t.Fatalf("codex_thread_id changed: %q", got)
	}
	if countingStore.updates != 0 {
		t.Fatalf("manifest updates: got %d, want 0", countingStore.updates)
	}
	if len(fixture.env) != 0 {
		t.Fatalf("set-environment calls: got %+v, want none", fixture.env)
	}
}

func TestDeliverMasterSessionRefusesWithCompatMessage(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-master", "master")
	fixture := newTransportFixture("party-master", tmux.RolePrimary)

	_, err := NewService(store, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-master", "hello")
	if err == nil {
		t.Fatal("expected master session to fail")
	}
	if got := err.Error(); got != CompanionNotAvailableMessage {
		t.Fatalf("error: got %q, want %q", got, CompanionNotAvailableMessage)
	}
	if len(fixture.sent) != 0 {
		t.Fatalf("sent calls: got %+v, want none", fixture.sent)
	}
}

func TestDeliverSendFailureSurfacesError(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	fixture := newTransportFixture("party-transport", tmux.RolePrimary)
	fixture.sendErr = errors.New("send failed")

	_, err := NewService(store, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "hello")
	if err == nil {
		t.Fatal("expected send failure")
	}
	if !strings.Contains(err.Error(), "send failed") {
		t.Fatalf("error should surface send failure, got %v", err)
	}
}

func TestDeliverCodexCaptureFailureWarnsButStillDelivers(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "party-transport", "worker")
	fixture := newTransportFixture("party-transport", tmux.RoleCompanion)
	fixture.currentWindow = 0
	t.Setenv("CODEX_THREAD_ID", "thread-123")

	result, err := NewService(failingUpdateStore{Store: store}, tmux.NewClient(fixture.runner())).Deliver(t.Context(), "party-transport", "done")
	if err != nil {
		t.Fatalf("Deliver: %v", err)
	}
	if len(fixture.sent) != 1 {
		t.Fatalf("sent calls: got %d, want 1", len(fixture.sent))
	}
	if len(result.Warnings) == 0 {
		t.Fatal("expected capture warning")
	}
	if got := readCodexThreadID(t, store, "party-transport"); got != "" {
		t.Fatalf("codex_thread_id: got %q, want empty after failed capture", got)
	}
}
