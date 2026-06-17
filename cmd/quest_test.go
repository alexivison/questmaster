package cmd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

// runQuest executes a quest subcommand against a temp QUESTMASTER_HOME, with
// the editor/opener injectable. Returns stdout and any execute error.
func runQuest(t *testing.T, opts []questOption, args ...string) (string, error) {
	t.Helper()
	cmd := newQuestCmd(opts...)
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&bytes.Buffer{})
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

func TestQuestNewProducesWIP(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	fixed := time.Unix(1780539999, 0).UTC()

	out, err := runQuest(t, []questOption{withQuestNow(func() time.Time { return fixed })}, "new")
	if err != nil {
		t.Fatalf("quest new: %v", err)
	}
	if !strings.Contains(out, "Created wip quest") {
		t.Errorf("unexpected output: %q", out)
	}

	q, err := quest.DefaultStore().Load("quest-1780539999")
	if err != nil {
		t.Fatalf("load created quest: %v", err)
	}
	if q.Status != quest.StatusWIP {
		t.Errorf("new quest status = %q, want wip", q.Status)
	}
	if q.ID != "quest-1780539999" {
		t.Errorf("generated quest id = %q, want quest-1780539999", q.ID)
	}
	if q.Agent != "" {
		t.Errorf("new quest agent = %q, want empty until a session is attached", q.Agent)
	}
	if err := quest.Validate(q); err != nil {
		t.Errorf("new quest is invalid: %v", err)
	}
}

func TestQuestNewWithoutIDAutoGeneratesQuestID(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	fixed := time.Unix(1780539999, 0).UTC()
	opts := []questOption{withQuestNow(func() time.Time { return fixed })}

	out, err := runQuest(t, opts, "new")
	if err != nil {
		t.Fatalf("quest new without id: %v", err)
	}
	if !strings.Contains(out, "quest-1780539999") {
		t.Errorf("output did not name generated quest id:\n%s", out)
	}
	q, err := quest.DefaultStore().Load("quest-1780539999")
	if err != nil {
		t.Fatalf("load generated quest: %v", err)
	}
	if q.ID != "quest-1780539999" {
		t.Fatalf("generated quest id = %q, want quest-1780539999", q.ID)
	}
	if strings.HasPrefix(q.ID, state.SessionIDPrefix) {
		t.Fatalf("generated quest id %q used the session namespace", q.ID)
	}

	if _, err := runQuest(t, opts, "new"); err != nil {
		t.Fatalf("quest new collision retry: %v", err)
	}
	if _, err := quest.DefaultStore().Load("quest-1780539999-1"); err != nil {
		t.Fatalf("load collision-suffixed quest: %v", err)
	}
}

func TestQuestNewHelpShowsGeneratedID(t *testing.T) {
	out, err := runQuest(t, nil, "new", "--help")
	if err != nil {
		t.Fatalf("quest new --help: %v", err)
	}
	if !strings.Contains(out, "new") || strings.Contains(out, "new [id]") {
		t.Fatalf("help should show no positional id:\n%s", out)
	}
	if !strings.Contains(out, "auto-generates") {
		t.Fatalf("help should mention generated ids:\n%s", out)
	}
}

func TestQuestNewRejectsPositionalID(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "new", "ENG-1"); err == nil {
		t.Fatalf("quest new should reject an authored id")
	}
}

func TestQuestNewStampsProject(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	fixed := time.Unix(1780539999, 0).UTC()
	opts := []questOption{
		withQuestNow(func() time.Time { return fixed }),
		withQuestProject(func() string { return "questmaster" }),
	}
	if _, err := runQuest(t, opts, "new"); err != nil {
		t.Fatalf("quest new: %v", err)
	}
	q, err := quest.DefaultStore().Load("quest-1780539999")
	if err != nil {
		t.Fatalf("load created quest: %v", err)
	}
	if q.Project != "questmaster" {
		t.Errorf("new quest project = %q, want questmaster (stamped from repo)", q.Project)
	}
}

func TestQuestNewOutsideRepoLeavesProjectEmpty(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	fixed := time.Unix(1780539999, 0).UTC()
	opts := []questOption{
		withQuestNow(func() time.Time { return fixed }),
		withQuestProject(func() string { return "" }), // not inside a git repo
	}
	if _, err := runQuest(t, opts, "new"); err != nil {
		t.Fatalf("quest new: %v", err)
	}
	q, err := quest.DefaultStore().Load("quest-1780539999")
	if err != nil {
		t.Fatalf("load created quest: %v", err)
	}
	if q.Project != "" {
		t.Errorf("new quest project = %q, want empty (no repo → Unsorted)", q.Project)
	}
}

func TestQuestEditRoundTripsAndRebuilds(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")

	// Editor that rewrites the summary and adds a heading block.
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, err := quest.ParseJSON(initial)
		if err != nil {
			return nil, err
		}
		q.Summary = "Edited objective"
		q.Body = append(q.Body, quest.Block{Type: quest.BlockHeading, Level: 2, Text: "Edited Section"})
		return quest.Marshal(q)
	}

	if _, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1"); err != nil {
		t.Fatalf("edit: %v", err)
	}

	q, err := quest.DefaultStore().Load("ENG-1")
	if err != nil {
		t.Fatalf("load after edit: %v", err)
	}
	if q.Summary != "Edited objective" {
		t.Errorf("edit did not persist summary: %q", q.Summary)
	}
	// The rebuilt HTML body must reflect the edited JSON.
	raw, err := quest.Build(q)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if !strings.Contains(string(raw), "<h2>Edited Section</h2>") {
		t.Errorf("rebuilt body missing the edited heading")
	}
}

func TestQuestEditRefusesMalformed(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")

	// Editor that introduces a schema violation (auto gate without a check).
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, _ := quest.ParseJSON(initial)
		q.Gates = append(q.Gates, quest.Gate{Name: "broken", Type: quest.GateAuto})
		return quest.Marshal(q)
	}

	_, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1")
	if err == nil {
		t.Fatalf("malformed edit should be refused")
	}
	if !strings.Contains(err.Error(), "auto requires a check") {
		t.Errorf("edit error = %q, want the validator error", err)
	}
}

func TestQuestEditCannotChangeStatus(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")
	// Editor tries to self-promote to active; edit must preserve wip.
	edit := func(_ string, initial []byte) ([]byte, error) {
		q, _ := quest.ParseJSON(initial)
		q.Status = quest.StatusActive
		return quest.Marshal(q)
	}
	if _, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1"); err != nil {
		t.Fatalf("edit: %v", err)
	}
	q, _ := quest.DefaultStore().Load("ENG-1")
	if q.Status != quest.StatusWIP {
		t.Errorf("edit changed status to %q; status is human-only via approve/done", q.Status)
	}
}

func TestQuestEditNeutralizesAuthoredAgent(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")
	edit := func(_ string, initial []byte) ([]byte, error) {
		return []byte(strings.Replace(string(initial), `"status": "wip"`, `"status": "wip",`+"\n  "+`"agent": "codex"`, 1)), nil
	}
	if _, err := runQuest(t, []questOption{withQuestEditor(edit)}, "edit", "ENG-1"); err != nil {
		t.Fatalf("edit: %v", err)
	}
	q, _ := quest.DefaultStore().Load("ENG-1")
	if q.Agent != "" {
		t.Errorf("edit persisted agent = %q, want empty runtime-derived agent", q.Agent)
	}
}

func TestQuestViewUsesTerminalRenderer(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	fixed := time.Unix(1780540000, 0).UTC()
	id := "quest-1780540000"
	if _, err := runQuest(t, []questOption{withQuestNow(func() time.Time { return fixed })}, "new", "--title", "Auth refresh", "--summary", "Fix the refresh loop"); err != nil {
		t.Fatalf("new: %v", err)
	}
	out, err := runQuest(t, nil, "view", id)
	if err != nil {
		t.Fatalf("view: %v", err)
	}
	q, _ := quest.DefaultStore().Load(id)
	want := quest.RenderDetail(q, quest.Runtime{}, 72)
	if !strings.Contains(out, want) {
		t.Errorf("view output is not the T2 detail render.\n got: %q\nwant contains: %q", out, want)
	}
}

func TestQuestRuntimeDerivesAgentFromAttachedPrimaryManifest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	stateRoot := t.TempDir()
	t.Setenv(state.StateRootEnv, stateRoot)
	q := &quest.Quest{ID: "DEMO-1", Title: "Demo", Summary: "s", Status: quest.StatusActive}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save quest: %v", err)
	}
	store, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-codex",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := state.StampQuest("qm-codex", "DEMO-1"); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	rt := questRuntime("DEMO-1")
	if rt.Agent != "codex" {
		t.Fatalf("runtime agent = %q, want codex", rt.Agent)
	}
	out, err := runQuest(t, nil, "view", "DEMO-1")
	if err != nil {
		t.Fatalf("quest view: %v", err)
	}
	if !strings.Contains(out, "codex") {
		t.Fatalf("quest view did not render attached primary agent:\n%s", out)
	}
	after, err := quest.DefaultStore().Load("DEMO-1")
	if err != nil {
		t.Fatalf("reload quest: %v", err)
	}
	if after.Agent != "" {
		t.Fatalf("quest view mutated agent to %q, want JSON unchanged", after.Agent)
	}
}

func TestQuestLsGroupsByProject(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuestProject(t, "ALPHA-1", quest.StatusActive, "s", "alpha")
	seedQuestProject(t, "ALPHA-2", quest.StatusWIP, "s", "alpha")
	seedQuest(t, "LOOSE-1", quest.StatusWIP, "s") // no project → Unsorted

	out, err := runQuest(t, nil, "ls")
	if err != nil {
		t.Fatalf("ls: %v", err)
	}
	// Project sections head the log; Unsorted is last.
	alphaAt, unsortedAt := strings.Index(out, "alpha"), strings.Index(out, "Unsorted")
	if alphaAt < 0 || unsortedAt < 0 || alphaAt > unsortedAt {
		t.Fatalf("ls did not section by project (alpha before Unsorted):\n%s", out)
	}
	// Status now rides on each row as a glyph: ◆ active, ○ wip.
	if !strings.Contains(out, "◆") || !strings.Contains(out, "○") {
		t.Errorf("ls rows missing status glyphs:\n%s", out)
	}
	for _, id := range []string{"ALPHA-1", "ALPHA-2", "LOOSE-1"} {
		if !strings.Contains(out, id) {
			t.Errorf("ls missing quest %s:\n%s", id, out)
		}
	}
}

func TestQuestDelete(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")

	out, err := runQuest(t, nil, "delete", "ENG-1")
	if err != nil {
		t.Fatalf("quest delete: %v", err)
	}
	if !strings.Contains(out, "Deleted quest ENG-1") {
		t.Errorf("unexpected output: %q", out)
	}
	if quest.DefaultStore().Exists("ENG-1") {
		t.Errorf("quest still present after delete")
	}
}

func TestQuestDeleteMissingErrors(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	if _, err := runQuest(t, nil, "delete", "ENG-404"); err == nil {
		t.Fatalf("delete of a missing quest should error")
	}
}

func TestQuestCommentAddListResolve(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	q := &quest.Quest{
		ID:      "COMMENT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates:   []quest.Gate{{Name: "review", Type: quest.GateToggle}},
		Related: []quest.RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
		Body:    []quest.Block{{ID: "body-1", Type: quest.BlockText, Text: "body text"}},
	}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save seed quest: %v", err)
	}
	fixed := time.Unix(1780540000, 0).UTC()
	opts := []questOption{
		withQuestNow(func() time.Time { return fixed }),
		withQuestAuthor(func() string { return "aleksi" }),
		withQuestEditor(func(_ string, _ []byte) ([]byte, error) {
			return []byte("Please tighten the review gate.\n"), nil
		}),
	}

	out, err := runQuest(t, opts, "comment", "add", "COMMENT-1", "--anchor", "gate:review")
	if err != nil {
		t.Fatalf("comment add: %v", err)
	}
	if !strings.Contains(out, "Added comment comment-1780540000") {
		t.Fatalf("unexpected add output:\n%s", out)
	}
	afterAdd, err := quest.DefaultStore().Load("COMMENT-1")
	if err != nil {
		t.Fatalf("load after add: %v", err)
	}
	if len(afterAdd.Comments) != 1 || afterAdd.Comments[0].Author != "aleksi" || afterAdd.Comments[0].Anchor.String() != "gate:review" {
		t.Fatalf("stored comment mismatch: %#v", afterAdd.Comments)
	}

	out, err = runQuest(t, nil, "comment", "list", "COMMENT-1")
	if err != nil {
		t.Fatalf("comment list: %v", err)
	}
	for _, want := range []string{"comment-1780540000", "gate:review", "open by aleksi", "Please tighten the review gate."} {
		if !strings.Contains(out, want) {
			t.Fatalf("list output missing %q:\n%s", want, out)
		}
	}

	out, err = runQuest(t, opts, "comment", "resolve", "COMMENT-1", "comment-1780540000")
	if err != nil {
		t.Fatalf("comment resolve: %v", err)
	}
	if !strings.Contains(out, "Resolved comment comment-1780540000") {
		t.Fatalf("unexpected resolve output:\n%s", out)
	}
	afterResolve, err := quest.DefaultStore().Load("COMMENT-1")
	if err != nil {
		t.Fatalf("load after resolve: %v", err)
	}
	if afterResolve.Comments[0].Status != quest.CommentResolved || afterResolve.Comments[0].ResolvedAt == "" {
		t.Fatalf("comment was not resolved: %#v", afterResolve.Comments[0])
	}

	out, err = runQuest(t, nil, "comment", "list", "COMMENT-1", "--open")
	if err != nil {
		t.Fatalf("comment list --open: %v", err)
	}
	if !strings.Contains(out, "No comments.") {
		t.Fatalf("open list should be empty after resolve:\n%s", out)
	}
}

func TestQuestCommentAddRejectsMissingAnchorBeforeEditor(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	q := &quest.Quest{ID: "COMMENT-1", Title: "Commented", Summary: "s", Status: quest.StatusActive}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save seed quest: %v", err)
	}
	editorCalled := false
	_, err := runQuest(t, []questOption{withQuestEditor(func(_ string, _ []byte) ([]byte, error) {
		editorCalled = true
		return []byte("body"), nil
	})}, "comment", "add", "COMMENT-1", "--anchor", "body:missing")
	if err == nil {
		t.Fatalf("missing body anchor should error")
	}
	if editorCalled {
		t.Fatalf("editor should not open for a missing anchor")
	}
	if !strings.Contains(err.Error(), "block anchors require body[].id") {
		t.Fatalf("error should explain missing body ids, got: %v", err)
	}
}

func TestParseCommentAnchorBlockItem(t *testing.T) {
	got, err := parseCommentAnchor("block:steps#item:1")
	if err != nil {
		t.Fatalf("parseCommentAnchor: %v", err)
	}
	if got.String() != "block:steps#item:1" || got.Item == nil || *got.Item != 1 {
		t.Fatalf("anchor = %#v string %q, want block item 1", got, got.String())
	}
	if _, err := parseCommentAnchor("gate:review#item:0"); err == nil {
		t.Fatal("parseCommentAnchor accepted #item on gate anchor")
	}
	if _, err := parseCommentAnchor("block:steps#item:-1"); err == nil {
		t.Fatal("parseCommentAnchor accepted negative item index")
	}
}

func TestQuestCheckRunsAutoGatesInWorktree(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	stateRoot := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", stateRoot)
	worktree := t.TempDir()

	s := quest.DefaultStore()
	q := &quest.Quest{ID: "DEMO-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
			{Name: "ci", Type: quest.GateAuto, Check: "cmd:false"},
			{Name: "build", Type: quest.GateAuto, Check: "cmd:definitely-missing-xyz"},
			{Name: "where", Type: quest.GateAuto, Check: "cmd:pwd"},
			{Name: "ui", Type: quest.GateToggle},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save quest: %v", err)
	}

	// An attached session provides the worktree.
	mstore, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	if err := mstore.Create(state.Manifest{SessionID: "qm-100", Cwd: worktree}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := state.StampQuest("qm-100", "DEMO-1"); err != nil {
		t.Fatalf("stamp: %v", err)
	}

	results, err := runQuestCheck(context.Background(), "DEMO-1")
	if err != nil {
		t.Fatalf("runQuestCheck: %v", err)
	}
	if len(results) != 4 {
		t.Fatalf("expected 4 auto results (toggle skipped), got %d", len(results))
	}
	byName := map[string]gate.Result{}
	for _, r := range results {
		byName[r.Gate] = r
	}
	if byName["tests"].Status != gate.StatusPass {
		t.Errorf("tests → %q, want pass", byName["tests"].Status)
	}
	if byName["ci"].Status != gate.StatusFail || byName["ci"].Misconfigured() {
		t.Errorf("ci → %q (a real failure, not misconfigured)", byName["ci"].Status)
	}
	if !byName["build"].Misconfigured() {
		t.Errorf("build (missing command) → %q, want misconfigured", byName["build"].Status)
	}
	// Ran in the session's worktree, not the main checkout.
	wantWT, _ := filepath.EvalSymlinks(worktree)
	gotWT, _ := filepath.EvalSymlinks(strings.TrimSpace(byName["where"].Output))
	if gotWT != wantWT {
		t.Errorf("ran in %q, want worktree %q", gotWT, wantWT)
	}

	// Results were written to the sidecar.
	loaded, err := gate.NewSidecar(questRuntimeDir()).Load("DEMO-1")
	if err != nil {
		t.Fatalf("sidecar load: %v", err)
	}
	if loaded.Gates["ci"].Status != gate.StatusFail {
		t.Errorf("sidecar missing the ci result: %+v", loaded.Gates)
	}
	// The check never mutates the quest JSON.
	after, _ := s.Load("DEMO-1")
	for _, g := range after.Gates {
		if g.Checked {
			t.Errorf("a check run mutated the quest JSON (gate %q checked)", g.Name)
		}
	}
}

func TestQuestCheckRunsGitHubGatesIntoSidecarWithoutMutatingQuest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	stateRoot := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", stateRoot)
	worktree := t.TempDir()
	installQuestFakeGH(t)
	t.Setenv("GH_VIEW_STDOUT", `{"number":42,"url":"https://github.com/acme/app/pull/42","state":"OPEN"}`)
	t.Setenv("GH_CHECKS_STDOUT", `[{"name":"test","workflow":"ci","bucket":"pass","state":"SUCCESS"}]`)

	s := quest.DefaultStore()
	q := &quest.Quest{ID: "GITHUB-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "ci", Type: quest.GateAuto, Check: "github:checks"},
			{Name: "ui", Type: quest.GateToggle},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save quest: %v", err)
	}
	before, err := os.ReadFile(s.Path("GITHUB-1"))
	if err != nil {
		t.Fatalf("read quest before check: %v", err)
	}

	mstore, err := state.NewStore(stateRoot)
	if err != nil {
		t.Fatalf("state store: %v", err)
	}
	if err := mstore.Create(state.Manifest{SessionID: "qm-100", Cwd: worktree}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	if err := state.StampQuest("qm-100", "GITHUB-1"); err != nil {
		t.Fatalf("stamp: %v", err)
	}

	results, err := runQuestCheck(context.Background(), "GITHUB-1")
	if err != nil {
		t.Fatalf("runQuestCheck: %v", err)
	}
	if len(results) != 1 || results[0].Gate != "ci" || results[0].Status != gate.StatusPass {
		t.Fatalf("github gate result = %+v, want ci pass", results)
	}
	loaded, err := gate.NewSidecar(questRuntimeDir()).Load("GITHUB-1")
	if err != nil {
		t.Fatalf("sidecar load: %v", err)
	}
	if loaded.Gates["ci"].Status != gate.StatusPass {
		t.Fatalf("sidecar ci status = %q, want pass", loaded.Gates["ci"].Status)
	}
	after, err := os.ReadFile(s.Path("GITHUB-1"))
	if err != nil {
		t.Fatalf("read quest after check: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("github gate check mutated quest JSON/html")
	}
}

func TestQuestCheckRefusesUnattachedQuest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", t.TempDir())
	seedQuest(t, "LONE-1", quest.StatusActive, "no session on it")
	if _, err := runQuestCheck(context.Background(), "LONE-1"); err == nil {
		t.Fatalf("check on an unattached quest should fail (no worktree)")
	}
}

// A quest with only toggle gates has nothing for qm to run, so check must
// succeed (empty result) without demanding an attached worktree.
func TestQuestCheckToggleOnlyQuestNeedsNoWorktree(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	t.Setenv("QUESTMASTER_STATE_ROOT", t.TempDir())
	q := &quest.Quest{ID: "TOGS-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "ui-ok", Type: quest.GateToggle},
			{Name: "review", Type: quest.GateToggle, Before: quest.BeforePR},
		}}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	results, err := runQuestCheck(context.Background(), "TOGS-1")
	if err != nil {
		t.Fatalf("toggle-only quest should not require a worktree: %v", err)
	}
	if len(results) != 0 {
		t.Errorf("expected no auto results for a toggle-only quest, got %d", len(results))
	}
}

func TestActiveQuestChoicesExcludesWIPAndDone(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	s := quest.DefaultStore()
	for _, q := range []*quest.Quest{
		{ID: "ACT-1", Title: "Active one", Summary: "s", Status: quest.StatusActive},
		{ID: "WIP-1", Title: "Draft", Summary: "s", Status: quest.StatusWIP},
		{ID: "DONE-1", Title: "Turned in", Summary: "s", Status: quest.StatusDone},
	} {
		if err := s.Save(q); err != nil {
			t.Fatalf("save %s: %v", q.ID, err)
		}
	}
	choices := activeQuestChoices()
	if len(choices) != 1 || choices[0].ID != "ACT-1" {
		t.Fatalf("activeQuestChoices = %+v, want only ACT-1 (wip/done excluded)", choices)
	}
	if choices[0].Title != "Active one" {
		t.Errorf("choice title = %q, want %q", choices[0].Title, "Active one")
	}
}

func TestQuestStatusMovesBetweenStates(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")

	steps := []struct {
		cmd  string
		want quest.Status
	}{
		{"approve", quest.StatusActive},
		{"done", quest.StatusDone},
		{"approve", quest.StatusActive}, // done → back to the board
		{"withdraw", quest.StatusWIP},   // active → back to draft
		{"done", quest.StatusDone},      // wip → straight to done
	}
	for _, st := range steps {
		if _, err := runQuest(t, nil, st.cmd, "ENG-1"); err != nil {
			t.Fatalf("%s: %v", st.cmd, err)
		}
		if q, _ := quest.DefaultStore().Load("ENG-1"); q.Status != st.want {
			t.Errorf("after %s, status = %q, want %q", st.cmd, q.Status, st.want)
		}
	}
}

func TestQuestOpenInvokesOpener(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	seedQuest(t, "ENG-1", quest.StatusWIP, "s")
	var opened string
	opener := func(path string) error { opened = path; return nil }
	if _, err := runQuest(t, []questOption{withQuestOpener(opener)}, "open", "ENG-1"); err != nil {
		t.Fatalf("open: %v", err)
	}
	if !strings.HasSuffix(opened, "ENG-1.html") {
		t.Errorf("opener got %q, want a path ending in ENG-1.html", opened)
	}
}

func installQuestFakeGH(t *testing.T) {
	t.Helper()
	bin := t.TempDir()
	path := filepath.Join(bin, "gh")
	script := `#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  printf '%s\n' "$GH_VIEW_STDOUT"
  exit ${GH_VIEW_EXIT:-0}
fi
if [ "$1" = "pr" ] && [ "$2" = "checks" ]; then
  printf '%s\n' "$GH_CHECKS_STDOUT"
  exit ${GH_CHECKS_EXIT:-0}
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 99
`
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake gh: %v", err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
}
