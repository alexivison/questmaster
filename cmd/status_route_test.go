package cmd

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestStatusWithoutReadableManifestUsesCompleteInventory(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, liveServer, wantError                            string
		corrupt, duplicate, unreadable, unavailable, lateLabel bool
	}{
		{name: "legacy missing", liveServer: "default"},
		{name: "legacy corrupt", liveServer: "default", corrupt: true},
		{name: "dedicated missing", liveServer: "questmaster"},
		{name: "absent everywhere", wantError: "read manifest"},
		{name: "duplicate ownership", liveServer: "default", duplicate: true, wantError: "multiple tmux servers"},
		{name: "unreadable registry", liveServer: "questmaster", unreadable: true, wantError: "parse tmux server labels"},
		{name: "unavailable server", liveServer: "questmaster", unavailable: true, wantError: "unavailable"},
		{name: "unrouteable label recorded later", liveServer: "questmaster", lateLabel: true, wantError: "dev_later"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := state.OpenStore(t.TempDir())
			const id = "qm-example"
			if tc.corrupt {
				if err := os.WriteFile(filepath.Join(store.Root(), id+".json"), []byte("{"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			hasCalls := map[string]int{}
			client := func(label string) *tmux.Client {
				return tmux.NewClient(auditRunner(func(_ context.Context, args ...string) (string, error) {
					live := tc.liveServer == label || tc.duplicate
					switch args[0] {
					case "list-sessions":
						if tc.unavailable && label == "default" {
							return "", context.DeadlineExceeded
						}
						if live {
							return id, nil
						}
						return "", nil
					case "has-session":
						hasCalls[label]++
						if live {
							return "", nil
						}
						return "", &tmux.ExitError{Code: 1}
					default:
						t.Fatalf("unexpected tmux call: %v", args)
						return "", nil
					}
				}))
			}
			legacy, named := client("default"), client("questmaster")
			router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "questmaster" }, nil)
			if tc.unreadable {
				if err := os.WriteFile(filepath.Join(store.Root(), "tmux-servers.json"), []byte("{"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if tc.lateLabel {
				if err := state.RecordTmuxServerLabel(store.Root(), "dev_later"); err != nil {
					t.Fatal(err)
				}
			}
			result, err := collectStatusRouted(t.Context(), store, named, router, id)
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("status error = %v, want %q", err, tc.wantError)
				}
				if len(hasCalls) != 0 {
					t.Errorf("guessed a server: %v", hasCalls)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if result.Status != "active" || result.Manifest.Present || result.Manifest.Corrupt != tc.corrupt || result.Manifest.Error == "" {
				t.Errorf("status = %+v", result)
			}
			if !tc.corrupt && result.Manifest.Error != "missing" {
				t.Errorf("manifest error = %q", result.Manifest.Error)
			}
			if len(hasCalls) != 1 || hasCalls[tc.liveServer] != 1 {
				t.Errorf("liveness calls = %v, want only %s", hasCalls, tc.liveServer)
			}
		})
	}
}

func TestStatusRoutesToRecordedServer(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-example", "example", "/tmp", "master")
	if err := store.Update("qm-example", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
		t.Fatal(err)
	}
	legacyCalls, namedCalls := 0, 0
	run := func(calls *int, live bool) *mockRunner {
		return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			if args[0] == "has-session" {
				(*calls)++
				if !live {
					return "", &tmux.ExitError{Code: 1}
				}
			}
			return "", nil
		}}
	}
	legacy, named := tmux.NewClient(run(&legacyCalls, false)), tmux.NewClient(run(&namedCalls, true))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	if _, err := collectStatusRouted(t.Context(), store, legacy, router, "qm-example"); err != nil {
		t.Fatal(err)
	}
	if legacyCalls != 0 || namedCalls != 1 {
		t.Fatalf("liveness calls: legacy=%d named=%d", legacyCalls, namedCalls)
	}
}
