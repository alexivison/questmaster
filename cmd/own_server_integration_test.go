//go:build linux || darwin

package cmd

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type rolloutFixture struct {
	store  *state.Store
	legacy *tmuxtest.Runner
	named  *tmuxtest.Runner
	old    *tmux.Client
	new    *tmux.Client
	router *tmuxroute.Router
	svc    *session.Service
	cli    string
}

func newRolloutFixture(t *testing.T, creation func() string) rolloutFixture {
	t.Helper()
	root, home := t.TempDir(), t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("HOME", home)
	t.Setenv("SHELL", "/bin/sh")
	t.Setenv("QUESTMASTER_TMUX_LABEL", "test_named")
	prependStubQuestmasterToPath(t)
	if err := tmuxconfig.Prepare(root); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(root)
	legacy, named := tmuxtest.NewRunner(t), tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	old, next := tmux.NewClient(legacy), tmux.NewClient(named)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": old, "test_named": next}, creation, []string{paths.Config, paths.Enforced})
	cli := filepath.Join(t.TempDir(), "fake-agent")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\nexec cat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"claude": {CLI: cli}},
		Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "claude", Window: -1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := session.NewService(store, old, "", registry)
	svc.Router = router
	svc.CLIResolver = func(string) (string, error) { return "true", nil }
	return rolloutFixture{store, legacy, named, old, next, router, svc, cli}
}

func (f rolloutFixture) startRecorded(t *testing.T, run *tmuxtest.Runner, id, server, kind, parent string) {
	t.Helper()
	pane, err := run.Run(t.Context(), "new-session", "-d", "-s", id, "-P", "-F", "#{pane_id}", "cat")
	if err != nil {
		t.Fatal(err)
	}
	if err := tmux.NewClient(run).SetPaneOption(t.Context(), pane, tmux.PaneRoleOption, tmux.RoleAgent); err != nil {
		t.Fatal(err)
	}
	m := state.Manifest{SessionID: id, Cwd: f.store.Root(), TmuxServer: state.TmuxServer(server), SessionType: kind,
		Agents: []state.AgentManifest{{Name: "claude", Role: "agent", CLI: f.cli, ResumeID: "resume-example"}}}
	if parent != "" {
		m.SetExtra("parent_session", parent)
	}
	if err := f.store.Create(m); err != nil {
		t.Fatal(err)
	}
}

func captureContains(t *testing.T, client *tmux.Client, id, marker string) bool {
	t.Helper()
	out, err := client.Capture(t.Context(), tmux.SessionTarget(id), 30)
	return err == nil && strings.Contains(out, marker)
}

func waitForCapture(t *testing.T, client *tmux.Client, id, marker string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !captureContains(t, client, id, marker) {
		if time.Now().After(deadline) {
			t.Fatalf("%s never captured %q", id, marker)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestIntegrationMixedRollout(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	f := newRolloutFixture(t, func() string { return "test_named" })
	f.startRecorded(t, f.legacy, "qm-old-master", "", "master", "")
	if _, err := f.legacy.Run(t.Context(), "new-session", "-d", "-s", "qm-sentinel", "sleep 60"); err != nil {
		t.Fatal(err)
	}
	worker, err := f.svc.Start(t.Context(), session.StartOpts{MasterID: "qm-old-master", Title: "Worker", Cwd: f.store.Root()})
	if err != nil {
		t.Fatal(err)
	}
	m, err := f.store.Read(worker.SessionID)
	if err != nil || m.TmuxServer != "test_named" {
		t.Fatalf("worker route = %q, %v", m.TmuxServer, err)
	}
	childEnv, err := f.named.Run(t.Context(), "show-environment", "-t", tmux.SessionTarget(worker.SessionID))
	if err != nil || !strings.Contains(childEnv, "QUESTMASTER_TMUX_SERVER=test_named") || !strings.Contains(childEnv, "QUESTMASTER_TMUX_LABEL=test_named") {
		t.Fatalf("worker environment = %q, %v", childEnv, err)
	}
	msg := message.NewServiceWithRouter(f.store, f.router)
	if got, err := msg.Report(t.Context(), worker.SessionID, "worker-report-marker"); err != nil || got != message.DeliverySubmitted {
		t.Fatalf("worker report = %q, %v", got, err)
	}
	if got, err := msg.RelayFrom(t.Context(), "qm-old-master", worker.SessionID, "master-send-marker"); err != nil || got != message.DeliverySubmitted {
		t.Fatalf("master send = %q, %v", got, err)
	}
	waitForCapture(t, f.old, "qm-old-master", "worker-report-marker")
	waitForCapture(t, f.new, worker.SessionID, "master-send-marker")
	snapshot, err := serve.NewSnapshotter(f.store, f.old, time.Now, f.router).TrackerForChange(serve.Change{})
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, row := range snapshot.Sessions {
		seen[row.ID] = true
	}
	if !seen["qm-old-master"] || !seen[worker.SessionID] {
		t.Fatalf("tracker rows = %+v", snapshot.Sessions)
	}
	writeManifestFile(t, f.store.Root(), "qm-stale-rollout", map[string]any{"session_id": "qm-stale-rollout"}, 10*24*time.Hour)
	f.router.Invalidate()
	if result, err := pruneManifestsWithLegacyRoot(t.Context(), f.store, f.old, 7, false, "", f.router); err != nil || result.Pruned != 1 {
		t.Fatalf("prune = %+v, %v", result, err)
	}
	for _, id := range []string{"qm-old-master", worker.SessionID} {
		if _, err := f.store.Read(id); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.store.Create(state.Manifest{SessionID: "qm-stopped-old", Cwd: f.store.Root(), SessionType: "master", Agents: []state.AgentManifest{{Name: "claude", Role: "agent", CLI: f.cli, ResumeID: "resume-example"}}}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.Continue(t.Context(), "qm-stopped-old"); err != nil {
		t.Fatal(err)
	}
	continued, err := f.store.Read("qm-stopped-old")
	if err != nil || continued.TmuxServer != "test_named" || continued.Agents[0].ResumeID != "resume-example" {
		t.Fatalf("continued route/resume = %+v, %v", continued, err)
	}
	if alive, err := f.new.HasSession(t.Context(), "qm-stopped-old"); err != nil || !alive {
		t.Fatalf("continued session on named server = %v, %v", alive, err)
	}
	if alive, err := f.old.HasSession(t.Context(), "qm-sentinel"); err != nil || !alive {
		t.Fatalf("legacy sentinel = %v, %v", alive, err)
	}
}

func TestIntegrationDevPaneCLISpawnKeepsOverride(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	f := newRolloutFixture(t, func() string {
		paths := tmuxconfig.Paths(os.Getenv(state.StateRootEnv))
		return tmux.DefaultServer(paths.Config, paths.Enforced).Label()
	})
	t.Setenv("CLAUDE_BIN", f.cli)
	shimDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(shimDir, "questmaster"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", shimDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	f.svc.Now = func() int64 { return time.Now().Add(-time.Minute).Unix() }
	master, err := f.svc.Start(t.Context(), session.StartOpts{Title: "Master", Cwd: f.store.Root()})
	if err != nil {
		t.Fatal(err)
	}
	paneEnv, err := f.named.Run(t.Context(), "show-environment", "-t", tmux.SessionTarget(master.SessionID))
	if err != nil {
		t.Fatal(err)
	}
	label := "QUESTMASTER_TMUX_LABEL=test_named"
	if !strings.Contains(paneEnv, label) {
		t.Fatalf("master pane has no dev creation label: %q", paneEnv)
	}
	t.Setenv("QUESTMASTER_TMUX_LABEL", strings.TrimPrefix(label, "QUESTMASTER_TMUX_LABEL="))
	if !strings.Contains(paneEnv, "QUESTMASTER_SESSION="+master.SessionID) {
		t.Fatalf("master pane has no session identity: %q", paneEnv)
	}
	t.Setenv("QUESTMASTER_SESSION", master.SessionID)
	cmd := NewRootCmd(WithDeps(f.store, f.old), WithTmuxRouter(f.router))
	var output bytes.Buffer
	cmd.SetOut(&output)
	cmd.SetArgs([]string{"spawn", "Worker"})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	var created struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(output.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	worker, err := f.store.Read(created.SessionID)
	if err != nil || worker.TmuxServer != "test_named" {
		t.Fatalf("CLI worker route = %+v, %v", worker, err)
	}
	if alive, err := f.new.HasSession(t.Context(), created.SessionID); err != nil || !alive {
		t.Fatalf("CLI worker on override socket = %v, %v", alive, err)
	}
}

func TestIntegrationProductionPaneHasNoDevOverride(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	f := newRolloutFixture(t, func() string { return "questmaster" })
	if err := os.Unsetenv("QUESTMASTER_TMUX_LABEL"); err != nil {
		t.Fatal(err)
	}
	if err := tmuxconfig.Prepare(f.store.Root()); err != nil {
		t.Fatal(err)
	}
	paths := tmuxconfig.Paths(f.store.Root())
	f.named = tmuxtest.NewRunnerWithConfig(t, paths.Config, paths.Enforced)
	f.new = tmux.NewClient(f.named)
	f.router = tmuxroute.New(f.store, map[string]*tmux.Client{"default": f.old, "questmaster": f.new}, func() string { return "questmaster" }, []string{paths.Config, paths.Enforced})
	f.svc.Router = f.router
	started, err := f.svc.Start(t.Context(), session.StartOpts{Title: "Production", Cwd: f.store.Root()})
	if err != nil {
		t.Fatal(err)
	}
	paneEnv, err := f.named.Run(t.Context(), "show-environment", "-t", tmux.SessionTarget(started.SessionID))
	if err != nil || strings.Contains(paneEnv, "QUESTMASTER_TMUX_LABEL=") || !strings.Contains(paneEnv, "QUESTMASTER_TMUX_SERVER=questmaster") {
		t.Fatalf("production pane environment = %q, %v", paneEnv, err)
	}
}

func TestIntegrationFlipBackKeepsNamedReachable(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	flipBack := false
	f := newRolloutFixture(t, func() string {
		if flipBack {
			return "default"
		}
		return "test_named"
	})
	if _, err := f.legacy.Run(t.Context(), "new-session", "-d", "-s", "qm-sentinel", "sleep 60"); err != nil {
		t.Fatal(err)
	}
	named, err := f.svc.Start(t.Context(), session.StartOpts{Title: "Named", Cwd: f.store.Root()})
	if err != nil {
		t.Fatal(err)
	}
	flipBack = true
	attach, handle, switchClient, err := attachPlan(t.Context(), f.store, f.router, named.SessionID)
	if err != nil || switchClient || handle.Label() != "test_named" || len(attach.Args) < 3 || attach.Args[1] != "-L" || attach.Args[2] != "test_named" {
		t.Fatalf("named attach after flip-back = %v, %+v, %v, %v", attach, handle, switchClient, err)
	}
	if got, err := f.svc.Continue(t.Context(), named.SessionID); err != nil || !got.Reattach {
		t.Fatalf("reattach named session = %+v, %v", got, err)
	}
	msg := message.NewServiceWithRouter(f.store, f.router)
	if got, err := msg.Relay(t.Context(), named.SessionID, "flip-back-marker"); err != nil || got != message.DeliverySubmitted {
		t.Fatalf("message to named session = %q, %v", got, err)
	}
	waitForCapture(t, f.new, named.SessionID, "flip-back-marker")
	if _, err := f.svc.Delete(t.Context(), named.SessionID); err != nil {
		t.Fatal(err)
	}
	if alive, err := f.new.HasSession(t.Context(), named.SessionID); err != nil || alive {
		t.Fatalf("deleted named session = %v, %v", alive, err)
	}
	legacy, err := f.svc.Start(t.Context(), session.StartOpts{Shell: true, Cwd: f.store.Root()})
	if err != nil {
		t.Fatal(err)
	}
	m, err := f.store.Read(legacy.SessionID)
	if err != nil || m.TmuxServer != "default" {
		t.Fatalf("flip-back creation route = %q, %v", m.TmuxServer, err)
	}
	if alive, err := f.old.HasSession(t.Context(), "qm-sentinel"); err != nil || !alive {
		t.Fatalf("legacy sentinel = %v, %v", alive, err)
	}
}

func TestIntegrationServerDeathIsolated(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	f := newRolloutFixture(t, func() string { return "test_named" })
	if _, err := f.legacy.Run(t.Context(), "new-session", "-d", "-s", "qm-sentinel", "sleep 60"); err != nil {
		t.Fatal(err)
	}
	started, err := f.svc.Start(t.Context(), session.StartOpts{Title: "Named", Cwd: f.store.Root(), ResumeIDs: map[string]string{"claude": "resume-example"}})
	if err != nil {
		t.Fatal(err)
	}
	ref := state.PullRequest{Key: "github.com/example/app#1", Host: "github.com", Owner: "example", Repo: "app", Number: 1}
	if _, err := state.WatchPullRequest(f.store.Root(), started.SessionID, ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	pidText, err := f.named.Run(t.Context(), "display-message", "-p", "#{pid}")
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(pidText)
	if err != nil || pid <= 0 {
		t.Fatalf("named server pid = %q, %v", pidText, err)
	}
	process, err := exec.Command("ps", "-p", pidText, "-o", "command=").Output()
	if err != nil || !strings.Contains(string(process), f.named.Socket()) {
		t.Fatalf("pid %d is not the private named server: %q, %v", pid, process, err)
	}
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		alive, err := f.new.HasSession(t.Context(), started.SessionID)
		if err == nil && !alive {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("named server remained live: %v, %v", alive, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if alive, err := f.old.HasSession(t.Context(), "qm-sentinel"); err != nil || !alive {
		t.Fatalf("legacy sentinel died with named server: %v, %v", alive, err)
	}
	if m, err := f.store.Read(started.SessionID); err != nil || m.TmuxServer != "test_named" {
		t.Fatalf("manifest after server death = %+v, %v", m, err)
	}
	if prs, err := state.LoadPullRequests(f.store.Root()); err != nil || len(prs) != 1 || len(prs[0].Watchers) != 1 || prs[0].Watchers[0].SessionID != started.SessionID {
		t.Fatalf("watch after server death = %+v, %v", prs, err)
	}
	if _, err := f.svc.Continue(t.Context(), started.SessionID); err != nil {
		t.Fatal(err)
	}
	if alive, err := f.new.HasSession(t.Context(), started.SessionID); err != nil || !alive {
		t.Fatalf("continued named session = %v, %v", alive, err)
	}
	if m, err := f.store.Read(started.SessionID); err != nil || m.Agents[0].ResumeID != "resume-example" {
		t.Fatalf("resume ID after server death = %+v, %v", m, err)
	}
}
