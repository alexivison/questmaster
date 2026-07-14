//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// allPassRunner returns a mock that accepts any tmux command and reports
// has-session as false (no existing sessions).
func allPassRunner() *mockRunner {
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) > 0 && args[0] == "list-sessions" {
			return "", &tmux.ExitError{Code: 1}
		}
		return "", nil
	}}
}

// hasSessionRunner returns a mock where has-session succeeds for the given sessions.
func hasSessionRunner(live ...string) *mockRunner {
	set := make(map[string]bool)
	for _, s := range live {
		set[s] = true
	}
	return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 3 && args[0] == "has-session" {
			if set[args[2]] {
				return "", nil
			}
			return "", &tmux.ExitError{Code: 1}
		}
		if len(args) >= 1 && args[0] == "list-sessions" {
			if len(live) == 0 {
				return "", &tmux.ExitError{Code: 1}
			}
			return strings.Join(live, "\n"), nil
		}
		return "", nil
	}}
}

func readOnlyNewManifest(t *testing.T, store *state.Store, exclude ...string) state.Manifest {
	t.Helper()

	ignored := make(map[string]struct{}, len(exclude))
	for _, id := range exclude {
		ignored[id] = struct{}{}
	}

	var ids []string
	entries, err := os.ReadDir(store.Root())
	if err != nil {
		t.Fatalf("ReadDir(%s): %v", store.Root(), err)
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".json")
		if _, skip := ignored[id]; skip {
			continue
		}
		ids = append(ids, id)
	}
	if len(ids) != 1 {
		t.Fatalf("expected exactly one new manifest, got %v", ids)
	}

	m, err := store.Read(ids[0])
	if err != nil {
		t.Fatalf("Read(%s): %v", ids[0], err)
	}
	return m
}

func manifestResumeID(agents []state.AgentManifest, role string) string {
	for _, spec := range agents {
		if spec.Role == role {
			return spec.ResumeID
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// start command tests
// ---------------------------------------------------------------------------

func TestStartCmd_Basic(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	out := runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "test-title")
	var got struct {
		SessionID string `json:"session_id"`
		Cwd       string `json:"cwd"`
		Title     string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("start output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.Cwd != cwd || got.Title != "test-title" {
		t.Fatalf("start JSON mismatch: %#v", got)
	}
}

func TestStartCmd_JSONAndPromptFile(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)
	promptPath := filepath.Join(t.TempDir(), "prompt.txt")
	if err := os.WriteFile(promptPath, []byte("inspect the JSON mode"), 0o644); err != nil {
		t.Fatalf("write prompt file: %v", err)
	}

	out := runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "--prompt-file", promptPath, "json-title")

	var got struct {
		SessionID  string `json:"session_id"`
		RuntimeDir string `json:"runtime_dir"`
		Cwd        string `json:"cwd"`
		Master     bool   `json:"master"`
		Title      string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("start output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.RuntimeDir == "" || got.Cwd != cwd || got.Master || got.Title != "json-title" {
		t.Fatalf("start JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if prompt := m.ExtraString("initial_prompt"); prompt != "inspect the JSON mode" {
		t.Fatalf("initial_prompt = %q, want prompt-file content", prompt)
	}
}

func TestStartCmd_RejectsPromptAndPromptFile(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	promptPath := filepath.Join(t.TempDir(), "prompt.txt")
	if err := os.WriteFile(promptPath, []byte("from file"), 0o644); err != nil {
		t.Fatalf("write prompt file: %v", err)
	}

	_, err := runCmdErr(t, store, allPassRunner(), "start", "--cwd", cwd, "--prompt", "inline", "--prompt-file", promptPath)
	if err == nil || !strings.Contains(err.Error(), "only one of --prompt or --prompt-file") {
		t.Fatalf("start with duplicate prompt sources error = %v", err)
	}
}

func TestStartCmd_RejectsMissingCwd(t *testing.T) {
	store := setupStore(t)
	missing := filepath.Join(t.TempDir(), "missing")
	writeAgentConfig(t, missing)

	_, err := runCmdErr(t, store, allPassRunner(), "start", "--cwd", missing)
	if err == nil || !strings.Contains(err.Error(), "working directory does not exist") {
		t.Fatalf("start with missing cwd error = %v", err)
	}
}

func TestStartCmd_RejectsRemovedNoCompanionFlag(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)

	_, err := runCmdErr(t, store, allPassRunner(),
		"start", "--cwd", cwd, "--primary", "codex", "--no-companion", "solo",
	)
	if err == nil {
		t.Fatal("expected error for removed --no-companion flag")
	}
	if !strings.Contains(err.Error(), "unknown flag") || !strings.Contains(err.Error(), "no-companion") {
		t.Fatalf("expected 'unknown flag --no-companion', got: %v", err)
	}
}

func TestStartCmd_ShellFlagCreatesAgentlessSession(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	cwd := t.TempDir()

	out := runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "--shell", "plain")
	var got struct {
		SessionID string `json:"session_id"`
		Cwd       string `json:"cwd"`
		Title     string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("start shell output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.Cwd != cwd || got.Title != "plain" {
		t.Fatalf("start shell JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if len(m.Agents) != 0 {
		t.Fatalf("shell manifest agents = %+v, want none", m.Agents)
	}
}

func TestStartCmd_RejectsShellConflicts(t *testing.T) {
	t.Parallel()

	tests := map[string][]string{
		"master":           {"start", "--shell", "--master"},
		"worker":           {"start", "--shell", "--master-id", "qm-master"},
		"prompt":           {"start", "--shell", "--prompt", "hello"},
		"prompt-file":      {"start", "--shell", "--prompt-file", "-"},
		"primary":          {"start", "--shell", "--primary", "codex"},
		"resume-agent":     {"start", "--shell", "--resume-agent", "primary=abc"},
		"model":            {"start", "--shell", "--model", "gpt-5.6-sol"},
		"reasoning-effort": {"start", "--shell", "--reasoning-effort", "ultra"},
	}
	for name, args := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			_, err := runCmdInputErr(t, setupStore(t), allPassRunner(), strings.NewReader("prompt"), args...)
			if err == nil || !strings.Contains(err.Error(), "start --shell") {
				t.Fatalf("start shell conflict error = %v, want start --shell guard", err)
			}
		})
	}
}

func TestStartCmd_ModelAndReasoningEffortReachPrimary(t *testing.T) {
	for name, master := range map[string]bool{
		"standalone": false,
		"master":     true,
	} {
		t.Run(name, func(t *testing.T) {
			store := setupStore(t)
			cwd := t.TempDir()
			writeAgentConfig(t, cwd)
			prependStubQuestmasterToPath(t)

			var calls []string
			runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
				calls = append(calls, strings.Join(args, " "))
				if len(args) > 0 && args[0] == "has-session" {
					return "", &tmux.ExitError{Code: 1}
				}
				return "", nil
			}}
			args := []string{"start", "--cwd", cwd, "--primary", "codex"}
			if master {
				args = append(args, "--master")
			}
			args = append(args, "--model", "gpt-5.6-sol", "--reasoning-effort", "ultra")
			runCmd(t, store, runner, args...)

			launch := strings.Join(calls, "\n")
			for _, want := range []string{"--model 'gpt-5.6-sol'", `model_reasoning_effort="ultra"`} {
				if !strings.Contains(launch, want) {
					t.Fatalf("start launch missing %q in:\n%s", want, launch)
				}
			}
		})
	}
}

func TestSessionCommandsDoNotExposeCompanionFlag(t *testing.T) {
	t.Parallel()

	root := NewRootCmd(
		WithDeps(setupStore(t), tmux.NewClient(allPassRunner())),
	)
	for _, name := range []string{"start", "spawn", "continue"} {
		cmd, _, err := root.Find([]string{name})
		if err != nil {
			t.Fatalf("find %s: %v", name, err)
		}
		if cmd.Flags().Lookup("companion") != nil {
			t.Fatalf("%s exposes removed --companion flag", name)
		}
	}
}

func TestStartCmd_MasterUsesPrimaryOnly(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	runCmd(t, store, allPassRunner(), "start", "--cwd", cwd, "--master", "--primary", "codex", "orchestrator")

	m := readOnlyNewManifest(t, store)
	if len(m.Agents) != 1 {
		t.Fatalf("expected master manifest with one primary, got %+v", m.Agents)
	}
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "codex" {
		t.Fatalf("master primary agent = %+v, want codex primary", m.Agents[0])
	}
	if m.SessionType != "master" {
		t.Fatalf("session type = %q, want master", m.SessionType)
	}
}

func TestStartCmd_ColorFlagPersistsMetadata(t *testing.T) {
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	out := runCmd(t, store, allPassRunner(),
		"start",
		"--cwd", cwd,
		"--color", "violet",
		"native modal",
	)
	var got struct {
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("start output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" {
		t.Fatalf("start JSON mismatch: %#v", got)
	}

	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if got := m.DisplayColor(); got != "violet" {
		t.Fatalf("display color = %q, want violet", got)
	}
}

// Note: master start is tested at the session-service level (TestStart_Master)
// where CLIResolver is mockable. The cmd layer only verifies cobra wiring.

// ---------------------------------------------------------------------------
// continue command tests
// ---------------------------------------------------------------------------

func TestContinueCmd_AlreadyRunning(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	createManifest(t, store, "qm-alive", "alive", cwd, "regular")

	out := runCmd(t, store, hasSessionRunner("qm-alive"), "continue", "qm-alive")
	var got struct {
		SessionID string `json:"session_id"`
		Reattach  bool   `json:"reattach"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("continue output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-alive" || !got.Reattach {
		t.Fatalf("continue JSON mismatch: %#v", got)
	}
}

func TestContinueCmd_JSON(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	createManifest(t, store, "qm-alive", "alive", cwd, "regular")

	out := runCmd(t, store, hasSessionRunner("qm-alive"), "continue", "qm-alive")

	var got struct {
		SessionID string `json:"session_id"`
		Reattach  bool   `json:"reattach"`
		Master    bool   `json:"master"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("continue output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-alive" || !got.Reattach || got.Master {
		t.Fatalf("continue JSON mismatch: %#v", got)
	}
}

func TestContinueCmd_MissingManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, allPassRunner(), "continue", "qm-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// delete command tests
// ---------------------------------------------------------------------------

func TestDeleteCmd_Basic(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-del", "deleteme", t.TempDir(), "regular")

	out := runCmd(t, store, hasSessionRunner("qm-del"), "delete", "qm-del")
	var got struct {
		SessionID string `json:"session_id"`
		Deleted   bool   `json:"deleted"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("delete output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-del" || !got.Deleted {
		t.Fatalf("delete JSON mismatch: %#v", got)
	}
}

func TestDeleteCmd_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-del", "deleteme", t.TempDir(), "regular")

	out := runCmd(t, store, hasSessionRunner("qm-del"), "delete", "qm-del")

	var got struct {
		SessionID string `json:"session_id"`
		Deleted   bool   `json:"deleted"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("delete output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-del" || !got.Deleted {
		t.Fatalf("delete JSON mismatch: %#v", got)
	}
}

func TestDeleteCmd_NoArgs(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	_, err := runCmdErr(t, store, allPassRunner(), "delete")
	if err == nil {
		t.Fatal("expected error with no args")
	}
}

// ---------------------------------------------------------------------------
// promote command tests
// ---------------------------------------------------------------------------

// TODO(cleanup): these cmd-level promote tests are thin wrappers around the
// service tests and share a lot of fixture setup — fold them in or delete.

func TestPromoteCmd_AlreadyMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-master", "orch", t.TempDir(), "master")

	out := runCmd(t, store, hasSessionRunner("qm-master"), "promote", "qm-master")
	var got struct {
		SessionID   string `json:"session_id"`
		SessionType string `json:"session_type"`
		Promoted    bool   `json:"promoted"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("promote output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-master" || got.SessionType != "master" || !got.Promoted {
		t.Fatalf("promote JSON mismatch: %#v", got)
	}
}

func TestPromoteCmd_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-regular", "regular", t.TempDir(), "master")

	out := runCmd(t, store, hasSessionRunner("qm-regular"), "promote", "qm-regular")

	var got struct {
		SessionID   string `json:"session_id"`
		SessionType string `json:"session_type"`
		Promoted    bool   `json:"promoted"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("promote output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-regular" || got.SessionType != "master" || !got.Promoted {
		t.Fatalf("promote JSON mismatch: %#v", got)
	}
}

func TestResizeCmd_Removed(t *testing.T) {
	t.Parallel()
	store := setupStore(t)

	_, err := runCmdErr(t, store, allPassRunner(), "resize", "qm-r")
	if err == nil {
		t.Fatal("expected removed resize command to be unknown")
	}
	if !strings.Contains(err.Error(), "unknown command") {
		t.Fatalf("resize error = %v, want unknown command", err)
	}
}

// ---------------------------------------------------------------------------
// spawn command tests
// ---------------------------------------------------------------------------

func TestSpawnCmd_Basic(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", cwd, "master")

	out := runCmd(t, store, allPassRunner(), "spawn", "qm-master", "worker-title")
	var got struct {
		SessionID string `json:"session_id"`
		MasterID  string `json:"master_id"`
		Title     string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("spawn output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.MasterID != "qm-master" || got.Title != "worker-title" {
		t.Fatalf("spawn JSON mismatch: %#v", got)
	}
}

func TestSpawnCmd_JSONAndPromptFileStdin(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", cwd, "master")

	out := runCmdInput(t, store, allPassRunner(), strings.NewReader("from stdin prompt"), "spawn", "qm-master", "worker-title", "--prompt-file", "-")

	var got struct {
		SessionID  string `json:"session_id"`
		MasterID   string `json:"master_id"`
		RuntimeDir string `json:"runtime_dir"`
		Cwd        string `json:"cwd"`
		Title      string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("spawn output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.MasterID != "qm-master" || got.RuntimeDir == "" || got.Cwd != cwd || got.Title != "worker-title" {
		t.Fatalf("spawn JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read spawned manifest: %v", err)
	}
	if prompt := m.ExtraString("initial_prompt"); prompt != "from stdin prompt" {
		t.Fatalf("initial_prompt = %q, want stdin prompt", prompt)
	}
}

func TestSpawnCmd_PromptSetsInitialPrompt(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", cwd, "master")

	task := "inspect the worker startup flow"
	runCmd(t, store, allPassRunner(), "spawn", "--prompt", task, "qm-master", "worker-title")

	m := readOnlyNewManifest(t, store, "qm-master")
	if got := m.ExtraString("initial_prompt"); got != task {
		t.Fatalf("initial_prompt = %q, want %q", got, task)
	}
}

func TestSpawnCmd_ResumeAgentUsesResolvedRole(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", cwd, "master")

	runCmd(t, store, allPassRunner(),
		"spawn",
		"--cwd", cwd,
		"--primary", "codex",
		"--resume-agent", "primary=codex-thread",
		"qm-master",
		"worker-title",
	)

	m := readOnlyNewManifest(t, store, "qm-master")
	if got := manifestResumeID(m.Agents, "primary"); got != "codex-thread" {
		t.Fatalf("primary resume = %q, want codex-thread", got)
	}
}

func TestSpawnCmd_NonMaster(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	createManifest(t, store, "qm-regular", "regular", t.TempDir(), "regular")

	_, err := runCmdErr(t, store, allPassRunner(), "spawn", "qm-regular")
	if err == nil {
		t.Fatal("expected error spawning from non-master")
	}
}

func TestParseResumeFlags_RejectsUnknownRole(t *testing.T) {
	t.Parallel()

	_, err := parseResumeFlags([]string{"wizard=abc123"})
	if err == nil {
		t.Fatal("expected invalid role error")
	}
}
