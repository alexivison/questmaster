//go:build linux || darwin

package message

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestIntegrationMixedMessages(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	legacyRun := tmuxtest.NewRunner(t)
	namedRun := tmuxtest.NewRunner(t)
	legacy := tmux.NewClient(legacyRun)
	named := tmux.NewClient(namedRun)
	start := func(run *tmuxtest.Runner, client *tmux.Client, id string) {
		t.Helper()
		pane, err := run.Run(t.Context(), "new-session", "-d", "-s", id, "-P", "-F", "#{pane_id}", "cat")
		if err != nil {
			t.Fatal(err)
		}
		if err := client.SetPaneOption(t.Context(), pane, tmux.PaneRoleOption, tmux.RoleAgent); err != nil {
			t.Fatal(err)
		}
	}
	start(legacyRun, legacy, "qm-master")
	start(namedRun, named, "qm-worker")
	start(namedRun, named, "qm-master")   // same-named sentinel on the other socket
	start(legacyRun, legacy, "qm-worker") // same-named sentinel on the other socket
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	routeManifest(t, store, "qm-master", "master", "dev_previous", "")
	routeManifest(t, store, "qm-worker", "worker", "questmaster", "qm-master")
	if err := store.Update("qm-master", func(m *state.Manifest) { m.Workers = []string{"qm-worker"} }); err != nil {
		t.Fatal(err)
	}
	router := tmuxroute.New(store, map[string]*tmux.Client{"dev_previous": legacy, "questmaster": named}, func() string { return "dev_previous" }, nil)
	svc := NewServiceWithRouter(store, router)
	if got, err := svc.Report(t.Context(), "qm-worker", "report-marker"); err != nil || got != DeliverySubmitted {
		t.Fatalf("report=%q %v", got, err)
	}
	if got, err := svc.RelayFrom(t.Context(), "qm-master", "qm-worker", "send-marker"); err != nil || got != DeliverySubmitted {
		t.Fatalf("send=%q %v", got, err)
	}
	if got, err := svc.BroadcastFrom(t.Context(), "qm-master", "qm-master", "broadcast-marker"); err != nil || got.Submitted != 1 {
		t.Fatalf("broadcast=%+v %v", got, err)
	}
	contains := func(client *tmux.Client, id, marker string) bool {
		out, err := client.Capture(context.Background(), tmux.SessionTarget(id), 30)
		return err == nil && strings.Contains(out, marker)
	}
	deadline := time.Now().Add(2 * time.Second)
	for !contains(legacy, "qm-master", "report-marker") || !contains(named, "qm-worker", "send-marker") || !contains(named, "qm-worker", "broadcast-marker") {
		if time.Now().After(deadline) {
			t.Fatal("routed messages missing from recipient panes")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if contains(named, "qm-master", "report-marker") || contains(legacy, "qm-worker", "send-marker") || contains(legacy, "qm-worker", "broadcast-marker") {
		t.Fatal("a same-named sentinel received a message")
	}
}
