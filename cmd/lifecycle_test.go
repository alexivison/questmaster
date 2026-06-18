//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
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

func TestSessionCommandsDoNotExposeCompanionFlag(t *testing.T) {
	t.Parallel()

	root := NewRootCmd(
		WithTUILauncher(func() error { return nil }),
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

func TestResizeCmd_JSON(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	runner := &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) >= 1 && args[0] == "list-panes" {
			return "0 0 tracker\n0 2 shell", nil
		}
		if len(args) >= 1 && args[0] == "resize-pane" {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	}}

	out := runCmd(t, store, runner, "resize", "qm-r")

	var got struct {
		SessionID string `json:"session_id"`
		Resized   bool   `json:"resized"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("resize output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID != "qm-r" || !got.Resized {
		t.Fatalf("resize JSON mismatch: %#v", got)
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

func TestSpawnCmd_QuestStampsWorkerAndPromptsByID(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	masterCwd := t.TempDir()
	workerCwd := t.TempDir()
	writeAgentConfig(t, masterCwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", masterCwd, "master")
	questMarker := "INLINE-BODY-SHOULD-NOT-BE-IN-PROMPT-" + strings.Repeat("x", 5000)
	seedQuest(t, "DEMO-1", quest.StatusActive, questMarker)

	userPrompt := "focus on the worker cwd"
	runner, calls := capturingRunner()
	out := runCmd(t, store, runner,
		"spawn",
		"--quest", "DEMO-1",
		"--cwd", workerCwd,
		"--prompt", userPrompt,
		"qm-master",
		"worker-title",
	)
	var spawned struct {
		SessionID string `json:"session_id"`
		Cwd       string `json:"cwd"`
		QuestID   string `json:"quest_id"`
	}
	if err := json.Unmarshal([]byte(out), &spawned); err != nil {
		t.Fatalf("spawn output is not JSON: %v\n%s", err, out)
	}
	if spawned.QuestID != "DEMO-1" || spawned.Cwd != workerCwd {
		t.Fatalf("spawn JSON mismatch: %#v", spawned)
	}

	m := readOnlyNewManifest(t, store, "qm-master")
	if got := m.Cwd; got != workerCwd {
		t.Fatalf("worker cwd = %q, want %q", got, workerCwd)
	}
	got, err := state.QuestIDForSession(m.SessionID)
	if err != nil {
		t.Fatalf("QuestIDForSession: %v", err)
	}
	if got != "DEMO-1" {
		t.Fatalf("spawned worker quest_id = %q, want DEMO-1", got)
	}
	initial := m.ExtraString("initial_prompt")
	for _, want := range []string{"quest DEMO-1", "questmaster quest view DEMO-1", userPrompt} {
		if !strings.Contains(initial, want) {
			t.Errorf("initial prompt missing %q:\n%s", want, initial)
		}
	}
	if strings.Contains(initial, questMarker) {
		t.Errorf("initial prompt inlined quest content")
	}
	if strings.Index(initial, "questmaster quest view DEMO-1") > strings.Index(initial, userPrompt) {
		t.Errorf("quest id instruction should be prepended before user prompt:\n%s", initial)
	}
	if joined := strings.Join(*calls, "\n"); strings.Contains(joined, questMarker) {
		t.Errorf("tmux command inlined quest content")
	}
}

func TestSpawnCmd_QuestRefusesNonActive(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	createManifest(t, store, "qm-master", "orch", cwd, "master")
	seedQuest(t, "WIP-1", quest.StatusWIP, "draft")
	seedQuest(t, "DONE-1", quest.StatusDone, "turned in")

	for _, id := range []string{"WIP-1", "DONE-1"} {
		_, err := runCmdErr(t, store, allPassRunner(), "spawn", "--quest", id, "qm-master", "worker-title")
		if err == nil {
			t.Errorf("spawn on %s should be refused", id)
		} else if !strings.Contains(err.Error(), "only active quests are attachable") {
			t.Errorf("unexpected refusal error for %s: %v", id, err)
		}
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
