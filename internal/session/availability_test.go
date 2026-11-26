//go:build linux || darwin

package session

import (
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

func TestStartRejectsDisabledBindingBeforeTmuxWork(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	if err := state.NewAgentAvailabilityStore(svc.Store.Root()).Set("claude", false); err != nil {
		t.Fatalf("disable claude: %v", err)
	}

	_, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "resume-1"}})
	if err == nil || !strings.Contains(err.Error(), "agent \"claude\" is disabled") || !strings.Contains(err.Error(), "--agent") {
		t.Fatalf("Start with disabled default = %v, want disabled-agent recovery hint", err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("Start made tmux calls before rejecting disabled agent: %v", runner.calls)
	}
}

func TestStartReportsAllOffAndStillAllowsShells(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	availability := state.NewAgentAvailabilityStore(svc.Store.Root())
	for _, name := range agent.Names() {
		if err := availability.Set(name, false); err != nil {
			t.Fatalf("disable %s: %v", name, err)
		}
	}
	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()}); err == nil || !strings.Contains(err.Error(), "all agents are disabled") {
		t.Fatalf("Start with every agent disabled = %v, want all-off error", err)
	}
	if len(runner.calls) != 0 {
		t.Fatalf("all-off Start made tmux calls: %v", runner.calls)
	}

	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Shell: true})
	if err != nil {
		t.Fatalf("Start shell with every agent disabled: %v", err)
	}
	manifest, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read shell manifest: %v", err)
	}
	if len(manifest.Agents) != 0 {
		t.Fatalf("shell agents = %+v, want none", manifest.Agents)
	}
}

func TestStartKeepsUnlistedProviderOnExistingResolverPath(t *testing.T) {
	t.Parallel()

	svc, _ := setupService(t)
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"stub": {CLI: "/bin/sh"}},
		Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "stub", Window: -1}},
	})
	if err != nil {
		t.Fatalf("create stub registry: %v", err)
	}
	svc.Registry = registry

	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatalf("Start unlisted provider: %v", err)
	}
	manifest, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(manifest.Agents) != 1 || manifest.Agents[0].Name != "stub" {
		t.Fatalf("manifest agents = %+v, want the stub provider", manifest.Agents)
	}
}

func TestSpawnRejectsDisabledInheritedAndExplicitAgentsBeforeTmuxWork(t *testing.T) {
	t.Parallel()

	for _, tc := range []struct {
		name      string
		disabled  string
		explicit  string
		wantAgent string
	}{
		{name: "inherited", disabled: "claude", wantAgent: "claude"},
		{name: "explicit override", disabled: "codex", explicit: "codex", wantAgent: "codex"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			svc, runner := setupService(t)
			masterID := "qm-master-" + strings.ReplaceAll(tc.name, " ", "-")
			if err := svc.Store.Create(state.Manifest{
				SessionID:   masterID,
				Cwd:         t.TempDir(),
				TmuxServer:  "questmaster",
				SessionType: "master",
				Agents:      []state.AgentManifest{{Name: "claude", Role: "agent", CLI: "/bin/sh"}},
			}); err != nil {
				t.Fatalf("create master manifest: %v", err)
			}
			if err := state.NewAgentAvailabilityStore(svc.Store.Root()).Set(tc.disabled, false); err != nil {
				t.Fatalf("disable %s: %v", tc.disabled, err)
			}
			registry := (*agent.Registry)(nil)
			if tc.explicit != "" {
				var err error
				registry, err = agent.NewRegistry(&agent.Config{
					Agents: map[string]agent.AgentConfig{tc.explicit: {CLI: "/bin/sh"}},
					Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: tc.explicit, Window: -1}},
				})
				if err != nil {
					t.Fatalf("create worker registry: %v", err)
				}
			}

			_, err := svc.Spawn(t.Context(), masterID, SpawnOpts{
				Title:     "worker",
				Cwd:       t.TempDir(),
				ResumeIDs: map[string]string{tc.wantAgent: "resume-1"},
				Registry:  registry,
			})
			if err == nil || !strings.Contains(err.Error(), `agent "`+tc.wantAgent+`" is disabled`) || !strings.Contains(err.Error(), "--agent") {
				t.Fatalf("Spawn with disabled %s = %v, want disabled-agent recovery hint", tc.wantAgent, err)
			}
			if len(runner.calls) != 0 {
				t.Fatalf("Spawn made tmux calls before rejecting disabled agent: %v", runner.calls)
			}
		})
	}
}

func TestContinueReattachesDisabledLiveSessionButBlocksRelaunch(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	started, err := svc.Start(t.Context(), StartOpts{
		Cwd:       t.TempDir(),
		ResumeIDs: map[string]string{"claude": "resume-1"},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := state.NewAgentAvailabilityStore(svc.Store.Root()).Set("claude", false); err != nil {
		t.Fatalf("disable claude: %v", err)
	}

	reattach, err := svc.Continue(t.Context(), started.SessionID)
	if err != nil {
		t.Fatalf("Continue live disabled session: %v", err)
	}
	if !reattach.Reattach {
		t.Fatalf("Continue result = %+v, want live reattach", reattach)
	}

	pane := runner.sessionPane(started.SessionID)
	runner.deadPanes[pane] = "17"
	beforeRespawn := len(callsAfter(runner, 0, "respawn-pane"))
	if _, err := svc.Continue(t.Context(), started.SessionID); err == nil || !strings.Contains(err.Error(), `agent "claude" is disabled`) || !strings.Contains(err.Error(), "Settings under Models and Reasoning") {
		t.Fatalf("Continue dead disabled pane = %v, want disabled error", err)
	}
	if got := len(callsAfter(runner, 0, "respawn-pane")); got != beforeRespawn {
		t.Fatalf("disabled dead pane respawn calls = %d, before %d", got, beforeRespawn)
	}

	delete(runner.sessions, started.SessionID)
	beforeNewSession := len(callsAfter(runner, 0, "new-session"))
	if _, err := svc.Continue(t.Context(), started.SessionID); err == nil || !strings.Contains(err.Error(), `agent "claude" is disabled`) || !strings.Contains(err.Error(), "Settings under Models and Reasoning") {
		t.Fatalf("Continue stopped disabled session = %v, want disabled error", err)
	}
	if got := len(callsAfter(runner, 0, "new-session")); got != beforeNewSession {
		t.Fatalf("disabled stopped session new-session calls = %d, before %d", got, beforeNewSession)
	}
}

func TestContinueReattachesLiveUnsupportedSessionAndRejectsRelaunch(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	started, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	const retiredAgent = "retired-agent"
	if err := svc.Store.Update(started.SessionID, func(m *state.Manifest) {
		m.Agents[0].Name = retiredAgent
	}); err != nil {
		t.Fatal(err)
	}
	if err := state.NewAgentAvailabilityStore(svc.Store.Root()).Set(retiredAgent, false); err != nil {
		t.Fatal(err)
	}
	attached, err := svc.Continue(t.Context(), started.SessionID)
	if err != nil || !attached.Reattach {
		t.Fatalf("continue live unsupported session = %+v, %v; want reattach", attached, err)
	}

	delete(runner.sessions, started.SessionID)
	before := len(callsAfter(runner, 0, "new-session"))
	_, err = svc.Continue(t.Context(), started.SessionID)
	if err == nil || !strings.Contains(err.Error(), "is not configured") {
		t.Fatalf("continue stopped unsupported session = %v, want provider resolution error", err)
	}
	if after := len(callsAfter(runner, 0, "new-session")); after != before {
		t.Fatalf("continue created %d sessions for an unsupported agent", after-before)
	}
}

func TestContinueMasterLeavesStoppedDisabledWorkerUnrevived(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	master, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "master-resume"}})
	if err != nil {
		t.Fatalf("Start master: %v", err)
	}
	svc.Now = uniqueSessionClock()
	worker, err := svc.Start(t.Context(), StartOpts{
		Cwd:       t.TempDir(),
		MasterID:  master.SessionID,
		Title:     "worker",
		ResumeIDs: map[string]string{"claude": "worker-resume"},
	})
	if err != nil {
		t.Fatalf("Start worker: %v", err)
	}
	if err := state.NewAgentAvailabilityStore(svc.Store.Root()).Set("claude", false); err != nil {
		t.Fatalf("disable claude: %v", err)
	}
	delete(runner.sessions, worker.SessionID)

	result, err := svc.Continue(t.Context(), master.SessionID)
	if err != nil {
		t.Fatalf("Continue live master: %v", err)
	}
	if len(result.RevivedWorkers) != 0 || len(result.FailedWorkers) != 1 || result.FailedWorkers[0] != worker.SessionID {
		t.Fatalf("Continue result = %+v, want stopped disabled worker listed as failed", result)
	}
	if runner.sessions[worker.SessionID] {
		t.Fatalf("disabled worker %s was relaunched", worker.SessionID)
	}
}
