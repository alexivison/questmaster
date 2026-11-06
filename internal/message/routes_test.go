//go:build linux || darwin

package message

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func routeFixture(t *testing.T, namedRecent ...bool) (*state.Store, *Service, *int, *int) {
	t.Helper()
	store := setupStore(t)
	legacySends, namedSends := 0, 0
	runner := func(sends *int) *mockRunner {
		return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			switch args[0] {
			case "has-session":
				return "", nil
			case "list-panes":
				return "0 0 agent", nil
			case "display-message":
				return livePaneDisplay(args), nil
			case "send-keys":
				if args[len(args)-1] != "Enter" {
					(*sends)++
				}
				return "", nil
			case "capture-pane":
				if sends == &namedSends {
					return "recipient output", nil
				}
				return "wrong server output", nil
			case "list-clients":
				if sends == &namedSends && len(namedRecent) > 0 && namedRecent[0] {
					return fmt.Sprintf("qm-alert\t%d", time.Now().Unix()), nil
				}
				return "", nil
			}
			return "", nil
		}}
	}
	legacy := tmux.NewClient(runner(&legacySends))
	named := tmux.NewClient(runner(&namedSends))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	return store, NewServiceWithRouter(store, router), &legacySends, &namedSends
}

func routeManifest(t *testing.T, store *state.Store, id, role, server, parent string) {
	t.Helper()
	m := state.Manifest{SessionID: id, SessionType: role, TmuxServer: state.TmuxServer(server), Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}
	if parent != "" {
		m.SetExtra("parent_session", parent)
	}
	if err := store.Create(m); err != nil {
		t.Fatal(err)
	}
}

func TestReportRoutesToParentServer(t *testing.T) {
	store, svc, legacy, named := routeFixture(t)
	routeManifest(t, store, "qm-parent", "master", "questmaster", "")
	routeManifest(t, store, "qm-worker", "worker", "default", "qm-parent")
	if _, err := svc.Report(t.Context(), "qm-worker", "ready"); err != nil {
		t.Fatal(err)
	}
	if *legacy != 0 || *named != 1 {
		t.Fatalf("sends: legacy=%d named=%d", *legacy, *named)
	}
}

func TestBroadcastRoutesPerWorker(t *testing.T) {
	store, svc, legacy, named := routeFixture(t)
	routeManifest(t, store, "qm-parent", "master", "default", "")
	routeManifest(t, store, "qm-old", "worker", "default", "qm-parent")
	routeManifest(t, store, "qm-new", "worker", "questmaster", "qm-parent")
	if err := store.Update("qm-parent", func(m *state.Manifest) { m.Workers = []string{"qm-old", "qm-new"} }); err != nil {
		t.Fatal(err)
	}
	result, err := svc.BroadcastFrom(t.Context(), "qm-parent", "qm-parent", "go")
	if err != nil || result.Submitted != 2 || *legacy != 1 || *named != 1 {
		t.Fatalf("result=%+v err=%v sends=%d/%d", result, err, *legacy, *named)
	}
}

func TestReadCapturesOnRecipientServer(t *testing.T) {
	store, svc, _, _ := routeFixture(t)
	routeManifest(t, store, "qm-worker", "worker", "questmaster", "")
	if err := store.Update("qm-worker", func(m *state.Manifest) { m.Agents = nil }); err != nil {
		t.Fatal(err)
	}
	got, err := svc.Read(t.Context(), "qm-worker", 10)
	if err != nil || !strings.Contains(got, "recipient output") {
		t.Fatalf("read=%q err=%v", got, err)
	}
}

func TestNotifyRoutesAndGatesOnRecipient(t *testing.T) {
	store, svc, legacy, named := routeFixture(t)
	routeManifest(t, store, "qm-alert", "worker", "questmaster", "")
	data := []byte(`{"session_id":"qm-alert","version":1,"panes":{"agent":{"role":"agent","state":"idle"}}}`)
	path := state.SessionStatePath(store.Root(), "qm-alert")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := svc.Notify(t.Context(), "qm-alert", "notice")
	if err != nil || got != DeliverySubmitted || *legacy != 0 || *named != 1 {
		t.Fatalf("notify=%q err=%v sends=%d/%d", got, err, *legacy, *named)
	}
	store, svc, legacy, named = routeFixture(t, true)
	routeManifest(t, store, "qm-alert", "worker", "questmaster", "")
	path = state.SessionStatePath(store.Root(), "qm-alert")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err = svc.Notify(t.Context(), "qm-alert", "notice")
	if err != nil || got != "" || *legacy != 0 || *named != 0 {
		t.Fatalf("recent typing was not gated: notify=%q err=%v sends=%d/%d", got, err, *legacy, *named)
	}
}

func TestClaudeNativeIdentityUsesRecipientClient(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	store := setupStore(t)
	legacyIdent, namedIdent := 0, 0
	runner := func(ident *int) *mockRunner {
		return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			switch args[0] {
			case "has-session":
				return "", nil
			case "list-panes":
				return "0 0 agent", nil
			case "display-message":
				if args[len(args)-1] == "#{pane_pid}\t#{session_name}:#{window_id}.#{pane_id}" {
					(*ident)++
					return fmt.Sprintf("%d\tqm-claude:@1.%%1", os.Getpid()), nil
				}
				return livePaneDisplay(args), nil
			case "send-keys":
				return "", nil
			}
			return "", nil
		}}
	}
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(runner(&legacyIdent)), "questmaster": tmux.NewClient(runner(&namedIdent))}, func() string { return "default" }, nil)
	svc := NewServiceWithRouter(store, router)
	routeManifest(t, store, "qm-claude", "worker", "questmaster", "")
	if err := store.Update("qm-claude", func(m *state.Manifest) { m.Agents[0].Name = "claude" }); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Relay(t.Context(), "qm-claude", "hello"); err != nil {
		t.Fatal(err)
	}
	if legacyIdent != 0 || namedIdent != 1 {
		t.Fatalf("pane identities: legacy=%d named=%d", legacyIdent, namedIdent)
	}
}
