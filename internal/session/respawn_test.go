//go:build linux || darwin

package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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
