//go:build linux || darwin

package session

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/state"
)

func callsAfter(runner *mockRunner, from int, command string) [][]string {
	var calls [][]string
	for _, c := range runner.calls[from:] {
		for _, cmd := range splitBatchArgs(c.args) {
			if len(cmd) > 0 && cmd[0] == command {
				calls = append(calls, cmd)
			}
		}
	}
	return calls
}

func setPiTestAgent(t *testing.T, svc *Service) {
	t.Helper()
	piCLI := filepath.Join(t.TempDir(), "pi")
	if err := os.WriteFile(piCLI, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write Pi fixture: %v", err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"pi": {CLI: piCLI}},
		Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "pi", Window: 0}},
	})
	if err != nil {
		t.Fatalf("create Pi registry: %v", err)
	}
	svc.Registry = registry
}

func setPiTestHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("PI_HOME", home)
	t.Setenv("PI_CODING_AGENT_DIR", "")
	return home
}

func addLegacyPiMessagingSymlink(t *testing.T, home string) string {
	t.Helper()
	link := filepath.Join(home, "agent", "extensions", "questmaster-messaging.ts")
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatalf("create Pi extensions dir: %v", err)
	}
	target := filepath.Join(t.TempDir(), "questmaster-messaging.ts")
	if err := os.WriteFile(target, []byte("const sessionID = process.env.QUESTMASTER_SESSION ?? '';\n"), 0o644); err != nil {
		t.Fatalf("write legacy Pi extension fixture: %v", err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("symlink legacy Pi extension: %v", err)
	}
	return link
}

func assertLegacyPiBlock(t *testing.T, err error, link string) {
	t.Helper()
	if err == nil {
		t.Fatal("operation succeeded with a legacy Pi extension symlink")
	}
	for _, want := range []string{link, "remove the symlink", "target will be left untouched"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err, want)
		}
	}
}

func TestStartRefusesLegacyPiExtensionSymlinkBeforeCreatingSession(t *testing.T) {
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	home := setPiTestHome(t)
	link := addLegacyPiMessagingSymlink(t, home)
	setPiTestAgent(t, svc)

	_, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Class: "paladin"})
	assertLegacyPiBlock(t, err, link)
	if runner.hasCall("new-session") {
		t.Fatal("Start created a tmux session before reporting the legacy Pi extension symlink")
	}
}

func TestContinueRefusesToRelaunchPiWithLegacyExtensionSymlinkBeforeCreatingSession(t *testing.T) {
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	home := setPiTestHome(t)
	setPiTestAgent(t, svc)
	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:       t.TempDir(),
		Class:     "paladin",
		ResumeIDs: map[string]string{"pi": "resume-pi"},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	link := addLegacyPiMessagingSymlink(t, home)
	delete(runner.sessions, result.SessionID)
	before := len(runner.calls)

	_, err = svc.Continue(t.Context(), result.SessionID)
	assertLegacyPiBlock(t, err, link)
	if creates := callsAfter(runner, before, "new-session"); len(creates) != 0 {
		t.Fatalf("Continue created a tmux session before reporting the legacy Pi extension symlink: %v", creates)
	}
}

func TestContinueRefusesPiRespawnWithLegacyExtensionSymlinkBeforeRespawningPane(t *testing.T) {
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	home := setPiTestHome(t)
	setPiTestAgent(t, svc)
	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:       t.TempDir(),
		Class:     "paladin",
		ResumeIDs: map[string]string{"pi": "resume-pi"},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	link := addLegacyPiMessagingSymlink(t, home)
	pane := runner.sessionPane(result.SessionID)
	runner.deadPanes[pane] = "17"
	before := len(runner.calls)

	_, err = svc.Continue(t.Context(), result.SessionID)
	assertLegacyPiBlock(t, err, link)
	if respawns := callsAfter(runner, before, "respawn-pane"); len(respawns) != 0 {
		t.Fatalf("Continue respawned a pane before reporting the legacy Pi extension symlink: %v", respawns)
	}
}

func TestContinuePublishesPiAccentBeforeRespawn(t *testing.T) {
	for _, kind := range []string{"missing accent", "missing runtime", "legacy manifest"} {
		t.Run(kind, func(t *testing.T) {
			svc, runner := setupService(t)
			svc.Now = uniqueSessionClock()
			setPiTestHome(t)
			setPiTestAgent(t, svc)

			result, err := svc.Start(t.Context(), StartOpts{
				Cwd: t.TempDir(), Class: "paladin", DisplayColor: "cyan",
				ResumeIDs: map[string]string{"pi": "resume-pi"},
			})
			if err != nil {
				t.Fatal(err)
			}
			dir := state.NewRuntimeDir(svc.Store.Root(), result.SessionID)
			colorPath := filepath.Join(dir, "pi-accent")
			if kind == "missing accent" {
				err = os.Remove(colorPath)
			} else {
				err = os.RemoveAll(dir)
			}
			if err != nil {
				t.Fatal(err)
			}
			if kind == "legacy manifest" {
				if err := svc.Store.Update(result.SessionID, func(m *state.Manifest) { m.RuntimeDir = "" }); err != nil {
					t.Fatal(err)
				}
			}
			runner.deadPanes[runner.sessionPane(result.SessionID)] = "17"
			baseRun := runner.fn
			runner.fn = func(ctx context.Context, args ...string) (string, error) {
				for _, cmd := range splitBatchArgs(args) {
					if len(cmd) > 0 && cmd[0] == "respawn-pane" {
						got, err := os.ReadFile(colorPath)
						if err != nil || string(got) != palette.Display("cyan") {
							t.Fatalf("before respawn, accent = %q, %v; want cyan", got, err)
						}
					}
				}
				return baseRun(ctx, args...)
			}
			got, err := svc.Continue(t.Context(), result.SessionID)
			if err != nil || !got.Respawned {
				t.Fatalf("Continue = %+v, %v; want a respawn", got, err)
			}
		})
	}
}

// Launch targets the pane new-session reported, never =name:0.0, so a server
// whose windows or panes count from 1 works.
func TestStartTargetsThePaneNewSessionReports(t *testing.T) {
	t.Parallel()
	for _, shell := range []bool{false, true} {
		svc, runner := setupService(t)
		svc.Now = uniqueSessionClock()
		result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Shell: shell, Title: "pane"})
		if err != nil {
			t.Fatalf("Start(shell=%v): %v", shell, err)
		}
		pane := runner.sessionPane(result.SessionID)
		if pane == "" {
			t.Fatalf("new-session reported no pane for %s", result.SessionID)
		}
		for _, c := range runner.calls {
			for _, cmd := range splitBatchArgs(c.args) {
				target := flagVal(cmd, "-t")
				if strings.HasSuffix(target, ":0.0") || strings.HasSuffix(target, ":0") {
					t.Fatalf("shell=%v: %s targets index 0: %v", shell, cmd[0], cmd)
				}
				if cmd[0] == "respawn-pane" && target != pane {
					t.Fatalf("shell=%v: respawn-pane target = %q, want %q", shell, target, pane)
				}
			}
		}
	}
}

// An agent that exited leaves a dead pane. Continue respawns it in that pane
// with the saved resume ID and records how it ended.
func TestContinueRespawnsADeadAgentWithItsResumeID(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "resume-1"}})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	pane := runner.sessionPane(result.SessionID)
	runner.deadPanes[pane] = "17"
	before := len(runner.calls)

	got, err := svc.Continue(t.Context(), result.SessionID)
	if err != nil {
		t.Fatalf("Continue: %v", err)
	}
	if !got.Reattach || !got.Respawned || got.AgentExit != "exit 17" {
		t.Fatalf("Continue = %+v, want a reattach that respawned an agent which exited 17", got)
	}
	respawns := callsAfter(runner, before, "respawn-pane")
	if len(respawns) != 1 || flagVal(respawns[0], "-t") != pane || !strings.Contains(respawns[0][len(respawns[0])-1], "--resume 'resume-1'") {
		t.Fatalf("respawn-pane calls = %v, want one in %s resuming resume-1", respawns, pane)
	}
	if got := runner.envVars[result.SessionID+":CLAUDE_SESSION_ID"]; got != "resume-1" {
		t.Fatalf("CLAUDE_SESSION_ID = %q", got)
	}
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if m.ExtraString("last_agent_exit") != "exit 17" || m.ExtraString("last_resumed_at") == "" {
		t.Fatalf("manifest after respawn: last_agent_exit=%q last_resumed_at=%q", m.ExtraString("last_agent_exit"), m.ExtraString("last_resumed_at"))
	}
}

// With no saved resume ID a respawn would start a new conversation in place of
// the one that ended, so Continue refuses and names the recovery.
func TestContinueRefusesToRespawnADeadAgentWithoutAResumeID(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	runner.deadPanes[runner.sessionPane(result.SessionID)] = "17"
	before := len(runner.calls)

	_, err = svc.Continue(t.Context(), result.SessionID)
	if err == nil {
		t.Fatal("Continue succeeded for a dead agent with no resume ID; want the gated error")
	}
	for _, want := range []string{"exit 17", "no saved Claude resume ID", "questmaster delete " + result.SessionID} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("Continue error %q does not mention %q", err, want)
		}
	}
	if respawns := callsAfter(runner, before, "respawn-pane"); len(respawns) != 0 {
		t.Fatalf("respawn-pane ran: %v", respawns)
	}
}

// A live agent pane is reattached as before.
func TestContinueLeavesALiveAgentPaneAlone(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = uniqueSessionClock()
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "resume-1"}})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	before := len(runner.calls)

	got, err := svc.Continue(t.Context(), result.SessionID)
	if err != nil {
		t.Fatalf("Continue: %v", err)
	}
	if !got.Reattach || got.Respawned {
		t.Fatalf("Continue = %+v, want a plain reattach", got)
	}
	if respawns := callsAfter(runner, before, "respawn-pane"); len(respawns) != 0 {
		t.Fatalf("respawn-pane ran for a live pane: %v", respawns)
	}
}

// A stopped session whose saved directory is gone is not relaunched in the
// daemon's directory: Continue says what is missing and how to repair it.
func TestContinueStoppedSessionWithAMissingCwdErrors(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	gone := filepath.Join(t.TempDir(), "removed-worktree")
	id := "qm-missing-cwd"
	createTestManifest(t, svc.Store, id, "gone", gone, "")

	_, err := svc.Continue(t.Context(), id)
	if err == nil {
		t.Fatal("Continue relaunched a session whose working directory is gone")
	}
	for _, want := range []string{gone, "mkdir -p", "questmaster delete " + id} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("Continue error %q does not mention %q", err, want)
		}
	}
	if runner.hasCall("new-session") {
		t.Fatal("Continue created a tmux session")
	}
	if _, err := os.Stat(gone); !os.IsNotExist(err) {
		t.Fatalf("Continue created the missing directory: %v", err)
	}
}
