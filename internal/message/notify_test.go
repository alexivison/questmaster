//go:build linux || darwin

package message

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestNotifyHoldsUnsafeSessionsAndRecentTyping(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name, agent, hook  string
		live, recent, want bool
	}{
		{"codex idle", "codex", "idle", true, false, true},
		{"opencode done", "opencode", "done", true, false, true},
		{"working", "codex", "working", true, false, false},
		{"stopped", "codex", "idle", false, false, false},
		{"typing", "opencode", "idle", true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store := setupStore(t)
			id := "qm-alert"
			if err := store.Create(state.Manifest{SessionID: id, Agents: []state.AgentManifest{{Name: tc.agent, Role: "agent"}}}); err != nil {
				t.Fatal(err)
			}
			dir := filepath.Dir(state.SessionStatePath(store.Root(), id))
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			data, _ := json.Marshal(state.SessionState{SessionID: id, Panes: map[string]state.PaneState{"agent": {Role: "agent", State: tc.hook}}})
			if err := os.WriteFile(state.SessionStatePath(store.Root(), id), data, 0o600); err != nil {
				t.Fatal(err)
			}
			sent := 0
			runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
				switch args[0] {
				case "has-session":
					if !tc.live {
						return "", &tmux.ExitError{Code: 1}
					}
					return "", nil
				case "list-panes":
					return "0 0 agent", nil
				case "list-clients":
					if tc.recent {
						return id + "\t" + strconv.FormatInt(time.Now().Unix(), 10), nil
					}
					return "", nil
				case "display-message":
					return "0", nil
				case "send-keys":
					if args[len(args)-1] != "Enter" {
						sent++
					}
					return "", nil
				}
				return "", nil
			}}
			svc := NewService(store, tmux.NewClient(runner))
			got, err := svc.Notify(context.Background(), id, "[PR owner/repo#12] activity")
			if err != nil || got != tc.want || (sent > 0) != tc.want {
				t.Fatalf("notify = %v, %v; sends=%d", got, err, sent)
			}
		})
	}
}
