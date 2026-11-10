package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestBackfillPreservesResumeAndWatches(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	store := state.OpenStore(root)
	for _, label := range []state.TmuxServer{"", "default"} {
		id := "qm-absent"
		if label != "" {
			id = "qm-explicit"
		}
		m := state.Manifest{SessionID: id, TmuxServer: label, RuntimeDir: state.NewRuntimeDir(root, id), Agents: []state.AgentManifest{{Name: "claude", Role: "agent", ResumeID: "example-resume"}}}
		m.SetExtra("keep", "unchanged")
		if err := store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	if err := store.Create(state.Manifest{SessionID: "qm-live"}); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-set", TmuxServer: "dev_example"}); err != nil {
		t.Fatal(err)
	}
	watches := []byte(`{"watches":[{"session_id":"qm-absent","url":"https://example.com/pr/1"}]}`)
	watchPath := filepath.Join(root, "pull_requests.json")
	if err := os.WriteFile(watchPath, watches, 0600); err != nil {
		t.Fatal(err)
	}
	runner := func(_ context.Context, args ...string) (string, error) {
		if args[0] != "list-sessions" && args[0] != "has-session" {
			t.Fatalf("backfill mutated tmux: %v", args)
		}
		if args[0] == "list-sessions" {
			return "qm-live", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}
	client := tmux.NewClient(auditRunner(runner))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": client, "questmaster": client, "dev_example": client}, func() string { return "questmaster" }, nil)
	run := func(backfill bool) map[string]json.RawMessage {
		t.Helper()
		var output bytes.Buffer
		cmd := NewRootCmd(WithDeps(store, client), WithTmuxRouter(router))
		cmd.SetOut(&output)
		args := []string{"tmux", "audit"}
		if backfill {
			args = append(args, "--backfill")
		}
		cmd.SetArgs(args)
		if err := cmd.Execute(); err != nil {
			t.Fatal(err)
		}
		var result map[string]json.RawMessage
		if err := json.Unmarshal(output.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	aged := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	path := filepath.Join(root, "qm-absent.json")
	if err := os.Chtimes(path, aged, aged); err != nil {
		t.Fatal(err)
	}
	before, err := store.Read("qm-absent")
	if err != nil {
		t.Fatal(err)
	}
	run(false)
	unchanged, _ := store.Read("qm-absent")
	if !reflect.DeepEqual(before, unchanged) {
		t.Fatal("read-only audit changed manifest")
	}
	result := run(true)
	var counts tmuxroute.BackfillResult
	if err := json.Unmarshal(result["backfill"], &counts); err != nil {
		t.Fatal(err)
	}
	if counts.Updated != 2 || counts.SkippedLive != 1 || counts.SkippedAlreadySet != 1 || counts.Failed != 0 {
		t.Fatalf("counts=%+v", counts)
	}
	after, _ := store.Read("qm-absent")
	after.TmuxServer = before.TmuxServer
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("changed fields beyond ownership: before=%+v after=%+v", before, after)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.ModTime().Equal(aged) {
		t.Fatalf("backfill changed manifest age: %s", info.ModTime())
	}
	explicit, _ := store.Read("qm-explicit")
	if explicit.TmuxServer != "questmaster" {
		t.Fatalf("explicit default=%q", explicit.TmuxServer)
	}
	live, _ := store.Read("qm-live")
	if live.TmuxServer != "" {
		t.Fatal("live ownership rewritten")
	}
	data, _ := os.ReadFile(watchPath)
	if !bytes.Equal(data, watches) {
		t.Fatal("watches changed")
	}
	result = run(true)
	if err := json.Unmarshal(result["backfill"], &counts); err != nil {
		t.Fatal(err)
	}
	if counts.Updated != 0 || counts.SkippedAlreadySet != 3 {
		t.Fatalf("non-idempotent=%+v", counts)
	}
}
