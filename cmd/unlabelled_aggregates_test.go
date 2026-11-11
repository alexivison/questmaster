package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
	"github.com/alexivison/questmaster/internal/tracker"
)

func TestUnlabelledManifestDoesNotBreakAggregates(t *testing.T) {
	for _, action := range []string{"list", "tracker", "routes", "recorded handles", "start"} {
		t.Run(action, func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("QUESTMASTER_STATE_ROOT", root)
			t.Setenv("HOME", t.TempDir())
			store := state.OpenStore(root)
			for _, m := range []state.Manifest{{SessionID: "qm-labelled", TmuxServer: "questmaster"}, {SessionID: "qm-unlabelled"}} {
				if err := store.Create(m); err != nil {
					t.Fatal(err)
				}
			}
			client := tmux.NewClient(auditRunner(func(_ context.Context, args ...string) (string, error) {
				switch args[0] {
				case "list-sessions":
					return "qm-labelled", nil
				case "has-session":
					if args[2] == tmux.SessionTarget("qm-labelled") {
						return "", nil
					}
					return "", &tmux.ExitError{Code: 1}
				case "new-session":
					return "%1", nil
				case "show-options":
					return tmuxconfig.RootMarker(root, "questmaster"), nil
				}
				return "", nil
			}))
			router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client}, func() string { return "questmaster" }, nil)
			switch action {
			case "list":
				var out bytes.Buffer
				cmd := NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
				cmd.SetOut(&out)
				cmd.SetArgs([]string{"list"})
				if err := cmd.Execute(); err != nil {
					t.Fatal(err)
				}
				var got listJSONOutput
				if err := json.Unmarshal(out.Bytes(), &got); err != nil {
					t.Fatal(err)
				}
				if len(got.Active) != 1 || got.Active[0].SessionID != "qm-labelled" || len(got.Resumable) != 1 || got.Resumable[0].SessionID != "qm-unlabelled" || got.Resumable[0].Live {
					t.Fatalf("list=%+v", got)
				}
			case "tracker":
				fetch := tracker.NewLiveSessionFetcher(client, store, state.NewProjectResolver(), router)
				got, err := fetch(tracker.SessionInfo{})
				if err != nil {
					t.Fatal(err)
				}
				statuses := map[string]string{}
				for _, row := range got.Sessions {
					statuses[row.ID] = row.Status
				}
				if statuses["qm-labelled"] != "active" || statuses["qm-unlabelled"] != "stopped" {
					t.Fatalf("statuses=%v", statuses)
				}
			case "routes":
				for _, liveOnly := range []bool{false, true} {
					got, err := router.Routes(t.Context(), nil, liveOnly)
					if err != nil {
						t.Fatal(err)
					}
					if len(got) != 1 || got[0].SessionID != "qm-labelled" || !got[0].Live {
						t.Fatalf("routes=%+v", got)
					}
				}
			case "recorded handles":
				got, err := router.RecordedHandles()
				if err != nil {
					t.Fatal(err)
				}
				if len(got) != 1 || got[0].Label() != "questmaster" {
					t.Fatalf("handles=%v", got)
				}
			case "start":
				svc := session.NewService(store, client, "")
				svc.Router = router
				svc.CLIResolver = func(string) (string, error) { return "true", nil }
				if _, err := svc.Start(t.Context(), session.StartOpts{Shell: true, Cwd: t.TempDir()}); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestUnlabelledActionsRequireBackfill(t *testing.T) {
	for _, label := range []state.TmuxServer{"", "default"} {
		for _, action := range []string{"continue", "status", "delete"} {
			t.Run(string(label)+"/"+action, func(t *testing.T) {
				root := t.TempDir()
				t.Setenv("QUESTMASTER_STATE_ROOT", root)
				store := state.OpenStore(root)
				if err := store.Create(state.Manifest{SessionID: "qm-old", TmuxServer: label, SessionType: "master", Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}, Workers: []string{"qm-labelled"}}); err != nil {
					t.Fatal(err)
				}
				if err := store.Create(state.Manifest{SessionID: "qm-labelled", TmuxServer: "questmaster"}); err != nil {
					t.Fatal(err)
				}
				client := tmux.NewClient(auditRunner(func(context.Context, ...string) (string, error) { return "", nil }))
				router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client}, func() string { return "questmaster" }, nil)
				cmd := NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
				cmd.SetArgs([]string{action, "qm-old"})
				if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "qm tmux audit --backfill") {
					t.Fatalf("%s error=%v", action, err)
				}
				if _, err := store.Read("qm-labelled"); err != nil {
					t.Fatal("refused action changed worker", err)
				}
			})
		}
	}
}
