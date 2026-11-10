package cmd

import (
	"bytes"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestSendCommandRoutesRecipientServer(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	if err := store.Update("qm-worker", func(m *state.Manifest) {
		m.TmuxServer = "questmaster"
		m.Agents[0].Name = "codex"
	}); err != nil {
		t.Fatal(err)
	}
	legacy, named := newSendCaptureRunner("qm-master", "qm-worker"), newSendCaptureRunner("qm-master", "qm-worker")
	legacyClient, namedClient := tmux.NewClient(legacy), tmux.NewClient(named)
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": legacyClient, "questmaster": namedClient}, func() string { return "dev_previous" }, nil)
	cmd := NewRootCmd(WithDeps(store, legacyClient), WithTmuxRouter(router))
	cmd.SetArgs([]string{"send", "qm-worker", "hello"})
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	if len(legacy.sends) != 0 || len(named.sends) != 1 {
		t.Fatalf("sends: legacy=%v named=%v", legacy.sends, named.sends)
	}
}
