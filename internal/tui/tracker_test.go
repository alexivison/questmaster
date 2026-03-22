package tui

import (
	"context"
	"fmt"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// ---------------------------------------------------------------------------
// Test doubles
// ---------------------------------------------------------------------------

type fakeActions struct {
	attachCalls    []string
	relayCalls     []relayCall
	broadcastCalls []broadcastCall
	spawnCalls     []spawnCall
	stopCalls      []string
	deleteCalls    []string
	manifestJSON   map[string]string
	err            error
}

type relayCall struct {
	workerID, message string
}
type broadcastCall struct {
	masterID, message string
}
type spawnCall struct {
	masterID, title string
}

func (f *fakeActions) Attach(_ context.Context, workerID string) error {
	f.attachCalls = append(f.attachCalls, workerID)
	return f.err
}
func (f *fakeActions) Relay(_ context.Context, workerID, message string) error {
	f.relayCalls = append(f.relayCalls, relayCall{workerID, message})
	return f.err
}
func (f *fakeActions) Broadcast(_ context.Context, masterID, message string) error {
	f.broadcastCalls = append(f.broadcastCalls, broadcastCall{masterID, message})
	return f.err
}
func (f *fakeActions) Spawn(_ context.Context, masterID, title string) error {
	f.spawnCalls = append(f.spawnCalls, spawnCall{masterID, title})
	return f.err
}
func (f *fakeActions) Stop(_ context.Context, workerID string) error {
	f.stopCalls = append(f.stopCalls, workerID)
	return f.err
}
func (f *fakeActions) Delete(_ context.Context, workerID string) error {
	f.deleteCalls = append(f.deleteCalls, workerID)
	return f.err
}
func (f *fakeActions) ManifestJSON(sessionID string) (string, error) {
	if f.manifestJSON == nil {
		return "", fmt.Errorf("no manifest")
	}
	j, ok := f.manifestJSON[sessionID]
	if !ok {
		return "", fmt.Errorf("manifest not found: %s", sessionID)
	}
	return j, nil
}

func stubFetcher(workers []WorkerRow) WorkerFetcher {
	return func(_ string) []WorkerRow { return workers }
}

func newTestTracker(workers []WorkerRow, actions *fakeActions) TrackerModel {
	return NewTrackerModel("party-master-1", stubFetcher(workers), actions)
}

func keyMsg(r rune) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}}
}

// ---------------------------------------------------------------------------
// Worker list rendering
// ---------------------------------------------------------------------------

func TestTracker_View_WorkerList_MultipleStates(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "bugfix-auth", Status: "active", Snippet: "fixing login flow"},
		{ID: "party-w2", Title: "refactor-db", Status: "stopped"},
		{ID: "party-w3", Title: "add-tests", Status: "active", Snippet: "running suite"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if !strings.Contains(view, "bugfix-auth") {
		t.Error("view should contain first worker title")
	}
	if !strings.Contains(view, "refactor-db") {
		t.Error("view should contain second worker title")
	}
	if !strings.Contains(view, "add-tests") {
		t.Error("view should contain third worker title")
	}
	// Active workers show filled circle
	if !strings.Contains(view, "●") {
		t.Error("view should contain active status indicator")
	}
	// Stopped workers show empty circle
	if !strings.Contains(view, "○") {
		t.Error("view should contain stopped status indicator")
	}
}

func TestTracker_View_WorkerList_ShowsSnippets(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "task-a", Status: "active", Snippet: "compiling modules"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if !strings.Contains(view, "compiling modules") {
		t.Error("wide view should show worker snippet")
	}
}

func TestTracker_View_EmptyWorkerList(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(nil, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if !strings.Contains(view, "No workers") {
		t.Error("empty worker list should show placeholder")
	}
	if !strings.Contains(view, "s") {
		t.Error("empty worker list should hint about spawn key")
	}
}

func TestTracker_View_WorkerCount(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
		{ID: "party-w2", Title: "b", Status: "stopped"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if !strings.Contains(view, "2 worker") {
		t.Error("header should show worker count")
	}
}

// ---------------------------------------------------------------------------
// Narrow-width rendering
// ---------------------------------------------------------------------------

func TestTracker_View_Compact_HidesSnippets(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "task-a", Status: "active", Snippet: "should be hidden"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 25 // very narrow — below snippet threshold
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if strings.Contains(view, "should be hidden") {
		t.Error("very narrow view should hide snippets")
	}
}

func TestTracker_View_Compact_ShortStatus(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "task-a", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 40 // below compactThreshold
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	// Compact mode should show just the dot, not "● active"
	if strings.Contains(view, "active") {
		t.Error("compact view should not show full status text")
	}
	if !strings.Contains(view, "●") {
		t.Error("compact view should still show status dot")
	}
}

// ---------------------------------------------------------------------------
// Cursor navigation
// ---------------------------------------------------------------------------

func TestTracker_Update_CursorNavigation(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
		{ID: "party-w2", Title: "b", Status: "active"},
		{ID: "party-w3", Title: "c", Status: "stopped"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.refreshWorkers()

	// Start at 0
	if tm.cursor != 0 {
		t.Fatalf("expected cursor=0, got %d", tm.cursor)
	}

	// Move down
	tm, _ = tm.Update(keyMsg('j'))
	if tm.cursor != 1 {
		t.Errorf("after j: expected cursor=1, got %d", tm.cursor)
	}

	// Move down again
	tm, _ = tm.Update(keyMsg('j'))
	if tm.cursor != 2 {
		t.Errorf("after j j: expected cursor=2, got %d", tm.cursor)
	}

	// Can't go past end
	tm, _ = tm.Update(keyMsg('j'))
	if tm.cursor != 2 {
		t.Errorf("at end, j should not move: expected cursor=2, got %d", tm.cursor)
	}

	// Move up
	tm, _ = tm.Update(keyMsg('k'))
	if tm.cursor != 1 {
		t.Errorf("after k: expected cursor=1, got %d", tm.cursor)
	}
}

func TestTracker_View_CursorIndicator(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "first", Status: "active"},
		{ID: "party-w2", Title: "second", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	if !strings.Contains(view, "▸") {
		t.Error("view should show cursor indicator on selected worker")
	}
}

// ---------------------------------------------------------------------------
// Action keys: attach
// ---------------------------------------------------------------------------

func TestTracker_Update_Enter_AttachesActiveWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.attachCalls) != 1 || actions.attachCalls[0] != "party-w1" {
		t.Errorf("enter should attach to active worker, got calls: %v", actions.attachCalls)
	}
}

func TestTracker_Update_Enter_IgnoresStoppedWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "stopped"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.attachCalls) != 0 {
		t.Error("enter should not attach to stopped worker")
	}
}

// ---------------------------------------------------------------------------
// Action keys: relay
// ---------------------------------------------------------------------------

func TestTracker_Update_R_EntersRelayMode(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('r'))

	if tm.mode != trackerModeRelay {
		t.Errorf("expected relay mode, got %v", tm.mode)
	}
}

func TestTracker_Update_Relay_SendsOnEnter(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	// Enter relay mode
	tm, _ = tm.Update(keyMsg('r'))

	// Type a message
	for _, r := range "hello worker" {
		tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}

	// Send
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.relayCalls) != 1 {
		t.Fatalf("expected 1 relay call, got %d", len(actions.relayCalls))
	}
	if actions.relayCalls[0].workerID != "party-w1" {
		t.Errorf("relay to wrong worker: %s", actions.relayCalls[0].workerID)
	}
	if actions.relayCalls[0].message != "hello worker" {
		t.Errorf("relay wrong message: %q", actions.relayCalls[0].message)
	}
	if tm.mode != trackerModeNormal {
		t.Error("should return to normal mode after send")
	}
}

func TestTracker_Update_Relay_EscCancels(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('r'))
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEsc})

	if tm.mode != trackerModeNormal {
		t.Error("esc should cancel relay mode")
	}
	if len(actions.relayCalls) != 0 {
		t.Error("esc should not send relay")
	}
}

// ---------------------------------------------------------------------------
// Action keys: broadcast
// ---------------------------------------------------------------------------

func TestTracker_Update_B_EntersBroadcastMode(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('b'))

	if tm.mode != trackerModeBroadcast {
		t.Errorf("expected broadcast mode, got %v", tm.mode)
	}
}

func TestTracker_Update_Broadcast_SendsOnEnter(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('b'))
	for _, r := range "update all" {
		tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.broadcastCalls) != 1 {
		t.Fatalf("expected 1 broadcast call, got %d", len(actions.broadcastCalls))
	}
	if actions.broadcastCalls[0].masterID != "party-master-1" {
		t.Errorf("broadcast wrong master: %s", actions.broadcastCalls[0].masterID)
	}
	if actions.broadcastCalls[0].message != "update all" {
		t.Errorf("broadcast wrong message: %q", actions.broadcastCalls[0].message)
	}
}

// ---------------------------------------------------------------------------
// Action keys: spawn
// ---------------------------------------------------------------------------

func TestTracker_Update_S_EntersSpawnMode(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(nil, &fakeActions{})
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('s'))

	if tm.mode != trackerModeSpawn {
		t.Errorf("expected spawn mode, got %v", tm.mode)
	}
}

func TestTracker_Update_Spawn_CreatesOnEnter(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	tm := newTestTracker(nil, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('s'))
	for _, r := range "new-worker" {
		tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEnter})

	if len(actions.spawnCalls) != 1 {
		t.Fatalf("expected 1 spawn call, got %d", len(actions.spawnCalls))
	}
	if actions.spawnCalls[0].title != "new-worker" {
		t.Errorf("spawn wrong title: %q", actions.spawnCalls[0].title)
	}
}

// ---------------------------------------------------------------------------
// Action keys: stop and delete
// ---------------------------------------------------------------------------

func TestTracker_Update_X_StopsSelectedWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
		{ID: "party-w2", Title: "b", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	// Move to second worker
	tm, _ = tm.Update(keyMsg('j'))
	tm, _ = tm.Update(keyMsg('x'))

	if len(actions.stopCalls) != 1 || actions.stopCalls[0] != "party-w2" {
		t.Errorf("x should stop selected worker, got calls: %v", actions.stopCalls)
	}
}

func TestTracker_Update_D_DeletesSelectedWorker(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "stopped"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('d'))

	if len(actions.deleteCalls) != 1 || actions.deleteCalls[0] != "party-w1" {
		t.Errorf("d should delete selected worker, got calls: %v", actions.deleteCalls)
	}
}

// ---------------------------------------------------------------------------
// Manifest inspect
// ---------------------------------------------------------------------------

func TestTracker_Update_M_ShowsWorkerManifest(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{
		manifestJSON: map[string]string{
			"party-w1": `{"party_id":"party-w1","title":"bugfix"}`,
		},
	}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "bugfix", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('m'))

	if tm.mode != trackerModeManifest {
		t.Errorf("expected manifest mode, got %v", tm.mode)
	}

	view := tm.View()
	if !strings.Contains(view, "Manifest") {
		t.Error("manifest view should contain 'Manifest' header")
	}
	if !strings.Contains(view, "party-w1") {
		t.Error("manifest view should contain session ID")
	}
}

func TestTracker_Update_ShiftM_ShowsMasterManifest(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{
		manifestJSON: map[string]string{
			"party-master-1": `{"party_id":"party-master-1","session_type":"master"}`,
		},
	}
	tm := newTestTracker(nil, actions)
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'M'}})

	if tm.mode != trackerModeManifest {
		t.Error("M should open master manifest")
	}
}

func TestTracker_Update_Manifest_EscReturns(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{
		manifestJSON: map[string]string{
			"party-w1": `{"party_id":"party-w1"}`,
		},
	}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('m'))
	tm, _ = tm.Update(tea.KeyMsg{Type: tea.KeyEsc})

	if tm.mode != trackerModeNormal {
		t.Error("esc should exit manifest mode")
	}
}

func TestTracker_Update_Manifest_ScrollJK(t *testing.T) {
	t.Parallel()

	// Long manifest that requires scrolling
	longJSON := strings.Repeat("line\n", 50)
	actions := &fakeActions{
		manifestJSON: map[string]string{"party-w1": longJSON},
	}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.width = 80
	tm.height = 10 // small viewport → scrolling needed
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('m'))
	if tm.manifestScrl != 0 {
		t.Fatalf("initial scroll should be 0, got %d", tm.manifestScrl)
	}

	tm, _ = tm.Update(keyMsg('j'))
	if tm.manifestScrl != 1 {
		t.Errorf("j should scroll down, got scroll=%d", tm.manifestScrl)
	}

	tm, _ = tm.Update(keyMsg('k'))
	if tm.manifestScrl != 0 {
		t.Errorf("k should scroll up, got scroll=%d", tm.manifestScrl)
	}
}

// ---------------------------------------------------------------------------
// Footer help text
// ---------------------------------------------------------------------------

func TestTracker_View_Footer_NormalMode(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	view := tm.View()

	for _, key := range []string{"j/k", "attach", "relay", "spawn", "manifest", "quit"} {
		if !strings.Contains(view, key) {
			t.Errorf("footer should contain %q", key)
		}
	}
}

func TestTracker_View_Footer_InputMode(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	tm, _ = tm.Update(keyMsg('r'))
	view := tm.View()

	if !strings.Contains(view, "send") {
		t.Error("input mode footer should mention send")
	}
	if !strings.Contains(view, "cancel") {
		t.Error("input mode footer should mention cancel")
	}
}

// ---------------------------------------------------------------------------
// Error display in footer
// ---------------------------------------------------------------------------

func TestTracker_View_Footer_ShowsActionError(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{err: fmt.Errorf("session not running")}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.width = 80
	tm.height = 24
	tm.refreshWorkers()

	// Stop will fail — error should appear in view
	tm, _ = tm.Update(keyMsg('x'))

	if tm.lastErr == nil {
		t.Fatal("expected lastErr to be set after failed stop")
	}

	view := tm.View()
	if !strings.Contains(view, "session not running") {
		t.Error("view should display action error in footer")
	}
}

func TestTracker_Update_ErrorClears_OnNextAction(t *testing.T) {
	t.Parallel()

	actions := &fakeActions{}
	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
	}
	tm := newTestTracker(workers, actions)
	tm.refreshWorkers()

	// Simulate a prior error
	tm.lastErr = fmt.Errorf("old error")

	// Next keypress (j) should clear it
	tm, _ = tm.Update(keyMsg('j'))

	if tm.lastErr != nil {
		t.Errorf("expected lastErr to be cleared on next action, got: %v", tm.lastErr)
	}
}

// ---------------------------------------------------------------------------
// Cursor bounds after refresh
// ---------------------------------------------------------------------------

func TestTracker_CursorClampedAfterRefresh(t *testing.T) {
	t.Parallel()

	callCount := 0
	fetcher := func(_ string) []WorkerRow {
		callCount++
		if callCount <= 1 {
			return []WorkerRow{
				{ID: "party-w1", Status: "active"},
				{ID: "party-w2", Status: "active"},
				{ID: "party-w3", Status: "active"},
			}
		}
		// Second call: only one worker remains
		return []WorkerRow{
			{ID: "party-w1", Status: "active"},
		}
	}

	tm := NewTrackerModel("party-master-1", fetcher, &fakeActions{})
	tm.refreshWorkers()

	// Move cursor to last worker
	tm, _ = tm.Update(keyMsg('j'))
	tm, _ = tm.Update(keyMsg('j'))
	if tm.cursor != 2 {
		t.Fatalf("expected cursor=2, got %d", tm.cursor)
	}

	// Refresh — only 1 worker now
	tm.refreshWorkers()
	if tm.cursor >= len(tm.workers) {
		t.Errorf("cursor should be clamped to valid range after refresh, cursor=%d, workers=%d",
			tm.cursor, len(tm.workers))
	}
}

// ---------------------------------------------------------------------------
// Q in normal mode does not quit (parent handles quit)
// ---------------------------------------------------------------------------

func TestTracker_Update_QInNormalMode_ReturnsQuitCmd(t *testing.T) {
	t.Parallel()

	tm := newTestTracker(nil, &fakeActions{})
	tm.refreshWorkers()

	_, cmd := tm.Update(keyMsg('q'))

	if cmd == nil {
		t.Error("q in normal mode should return a quit command for parent to handle")
	}
}

// ---------------------------------------------------------------------------
// Input mode blocks normal keys
// ---------------------------------------------------------------------------

func TestTracker_Update_InputMode_BlocksNavKeys(t *testing.T) {
	t.Parallel()

	workers := []WorkerRow{
		{ID: "party-w1", Title: "a", Status: "active"},
		{ID: "party-w2", Title: "b", Status: "active"},
	}
	tm := newTestTracker(workers, &fakeActions{})
	tm.refreshWorkers()

	// Enter relay mode
	tm, _ = tm.Update(keyMsg('r'))
	initialCursor := tm.cursor

	// j should be captured by text input, not move cursor
	tm, _ = tm.Update(keyMsg('j'))
	if tm.cursor != initialCursor {
		t.Error("j in input mode should not move cursor")
	}
}
