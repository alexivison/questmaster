package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func newTestRunner(t *testing.T) (*HookRunner, *recordedHookCalls) {
	t.Helper()
	t.Setenv("CODEX_THREAD_ID", "")
	rec := &recordedHookCalls{}
	r := &HookRunner{
		Now: func() time.Time {
			// Fixed timestamp keeps assertions deterministic; the
			// production Now is time.Now.
			return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)
		},
		LoadTranscriptTail: func(path string) ([]byte, error) {
			rec.transcriptPaths = append(rec.transcriptPaths, path)
			return rec.transcriptTail, nil
		},
		LoadState: func(string) (*state.SessionState, error) {
			return rec.lastState, nil
		},
		Update: func(sessionID string, mutate func(*state.SessionState) bool) error {
			rec.updateCalls++
			ss := rec.lastState
			if ss == nil {
				ss = &state.SessionState{SessionID: sessionID, Version: state.SchemaVersion, Panes: map[string]state.PaneState{}}
			}
			if mutate(ss) {
				rec.lastState = ss
				rec.writeCalls++
			}
			return nil
		},
		AppendEvent: func(sessionID string, ev state.StateEvent) error {
			rec.events = append(rec.events, ev)
			return nil
		},
	}
	return r, rec
}

type recordedHookCalls struct {
	events          []state.StateEvent
	updateCalls     int
	writeCalls      int
	lastState       *state.SessionState
	transcriptPaths []string
	transcriptTail  []byte
}

func chatEntries(event state.StateEvent) []map[string]interface{} {
	if entries, ok := event.Fields["chat_entries"].([]interface{}); ok {
		out := make([]map[string]interface{}, 0, len(entries))
		for _, raw := range entries {
			if fields, ok := raw.(map[string]interface{}); ok {
				out = append(out, fields)
			}
		}
		return out
	}
	if kind, ok := event.Fields["chat_kind"].(string); ok {
		return []map[string]interface{}{{"chat_kind": kind, "chat_text": event.Fields["chat_text"]}}
	}
	return nil
}

func chatKinds(event state.StateEvent) []string {
	entries := chatEntries(event)
	kinds := make([]string, 0, len(entries))
	for _, entry := range entries {
		kind, _ := entry["chat_kind"].(string)
		kinds = append(kinds, kind)
	}
	return kinds
}

func chatTextFor(event state.StateEvent, kind string) string {
	for _, entry := range chatEntries(event) {
		if entry["chat_kind"] == kind {
			text, _ := entry["chat_text"].(string)
			return text
		}
	}
	return ""
}

func TestHookChatEntriesForHarnesses(t *testing.T) {
	for _, tc := range []struct {
		name       string
		agent      string
		action     string
		payload    map[string]interface{}
		final      string
		finalEvent string
	}{
		{name: "claude", agent: "claude", action: "tool_start", payload: map[string]interface{}{"tool_name": "Bash"}, final: "last_assistant_message", finalEvent: "done"},
		{name: "codex", agent: "codex", action: "tool_start", payload: map[string]interface{}{"tool_name": "Bash"}, final: "last_assistant_message", finalEvent: "done"},
		{name: "pi", agent: "pi", action: "tool_execution_start", payload: map[string]interface{}{"toolName": "Bash"}, final: "messages", finalEvent: "agent_end"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, tc.agent, tc.action, "qm-chat", tc.payload)
			if got := chatKinds(rec.events[len(rec.events)-1]); !slices.Equal(got, []string{"status", "action"}) {
				t.Fatalf("tool event chat kinds = %v, want status and action", got)
			}

			finalText := strings.Join([]string{strings.Repeat("猫", 1501), "second paragraph", "third paragraph", "fourth"}, "\n\n")
			payload := map[string]interface{}{tc.final: finalText}
			if tc.final == "messages" {
				payload[tc.final] = []string{finalText}
			}
			runHookWithStdin(r, tc.agent, tc.finalEvent, "qm-chat", payload)
			last := rec.events[len(rec.events)-1]
			message := chatTextFor(last, "message")
			if len([]rune(message)) != 1500 || strings.Contains(message, "fourth") {
				runes := []rune(message)
				if len(runes) > 4 {
					runes = runes[len(runes)-4:]
				}
				t.Fatalf("capped final message runes=%d, suffix=%q", len([]rune(message)), string(runes))
			}
			if !slices.Contains(chatKinds(last), "status") || last.Fields["chat_summary"] != nil {
				t.Fatalf("final event chat kinds/summary = %v/%v", chatKinds(last), last.Fields["chat_summary"])
			}
		})
	}
}

func TestHookSubagentTaggingAndChatExclusion(t *testing.T) {
	for _, agent := range []string{"claude", "codex"} {
		t.Run(agent, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, agent, "tool_start", "qm-chat", map[string]interface{}{
				"agent_id": "task-42", "agent_type": "explorer", "tool_name": "Bash",
			})
			event := rec.events[len(rec.events)-1]
			if event.AgentID != "task-42" || event.AgentType != "explorer" || len(chatEntries(event)) != 0 {
				t.Fatalf("subagent event = %+v, feed entries %v", event, chatEntries(event))
			}
			if event.Fields["agent_id"] != nil || event.Fields["agent_type"] != nil {
				t.Fatalf("duplicate subagent fields: %#v", event.Fields)
			}
		})
	}
}

func TestHookClaudeMessageDisplay(t *testing.T) {
	cases := []struct {
		name   string
		inputs []struct {
			action  string
			payload map[string]interface{}
		}
		wantSay     []string
		wantMessage []string
		checkSayIn  bool
		sayInput    int
		sayInHook   string
	}{
		{
			name: "assembles indexed batches and emits in the completing hook",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"message_id": "m1", "prompt_id": "p1", "index": 1, "final": true, "delta": "layout."}},
				{action: "say", payload: map[string]interface{}{"message_id": "m1", "prompt_id": "p1", "index": 0, "delta": "Checking the\n"}},
			},
			wantSay:    []string{"Checking the\nlayout."},
			checkSayIn: true,
			sayInput:   1,
			sayInHook:  "Checking the\nlayout.",
		},
		{
			name: "Stop skips the final message after emitting the same say",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"message_id": "m2", "prompt_id": "p2", "transcript_path": "/tmp/t.jsonl", "index": 0, "final": true, "delta": "Done."}},
				{action: "done", payload: map[string]interface{}{"prompt_id": "p2", "transcript_path": "/tmp/t.jsonl", "last_assistant_message": "Done."}},
			},
			wantSay:    []string{"Done."},
			checkSayIn: true,
			sayInput:   0,
			sayInHook:  "Done.",
		},
		{
			name: "late display callback is suppressed by Stop text",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "done", payload: map[string]interface{}{"prompt_id": "p3", "transcript_path": "/tmp/t.jsonl", "last_assistant_message": "Done."}},
				{action: "say", payload: map[string]interface{}{"message_id": "m3", "prompt_id": "p3", "transcript_path": "/tmp/t.jsonl", "index": 0, "final": true, "delta": "Done."}},
			},
			wantMessage: []string{"Done."},
			checkSayIn:  true,
			sayInput:    1,
		},
		{
			name: "subagent display is excluded",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"agent_id": "task-1", "message_id": "m4", "index": 0, "final": true, "delta": "private subagent text"}},
			},
		},
		{
			name: "say text uses the shared cap",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"message_id": "m5", "index": 0, "final": true, "delta": strings.Repeat("猫", 1501)}},
			},
			wantSay:    []string{strings.Repeat("猫", 1500)},
			checkSayIn: true,
			sayInput:   0,
			sayInHook:  strings.Repeat("猫", 1500),
		},
		{
			name: "leading whitespace does not consume the cap",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"message_id": "m6", "index": 0, "final": true, "delta": strings.Repeat(" ", 2000) + "visible"}},
			},
			wantSay:    []string{"visible"},
			checkSayIn: true,
			sayInput:   0,
			sayInHook:  "visible",
		},
		{
			name: "out of order leading whitespace batches do not consume the cap",
			inputs: []struct {
				action  string
				payload map[string]interface{}
			}{
				{action: "say", payload: map[string]interface{}{"message_id": "m7", "index": 2, "final": true, "delta": "visible"}},
				{action: "say", payload: map[string]interface{}{"message_id": "m7", "index": 1, "delta": strings.Repeat(" ", 2000)}},
				{action: "say", payload: map[string]interface{}{"message_id": "m7", "index": 0, "delta": strings.Repeat(" ", 2000)}},
			},
			wantSay:    []string{"visible"},
			checkSayIn: true,
			sayInput:   2,
			sayInHook:  "visible",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			for _, input := range tc.inputs {
				runHookWithStdin(r, "claude", input.action, "qm-chat", input.payload)
			}
			if tc.checkSayIn {
				if got := chatTextFor(rec.events[tc.sayInput], "say"); got != tc.sayInHook {
					t.Fatalf("completing hook say = %q, want %q", got, tc.sayInHook)
				}
			}
			var say, messages []string
			for _, event := range rec.events {
				for _, entry := range chatEntries(event) {
					text, _ := entry["chat_text"].(string)
					switch entry["chat_kind"] {
					case "say":
						say = append(say, text)
					case "message":
						messages = append(messages, text)
					}
				}
			}
			if !slices.Equal(say, tc.wantSay) || !slices.Equal(messages, tc.wantMessage) {
				t.Fatalf("say/messages = %#v/%#v, want %#v/%#v", say, messages, tc.wantSay, tc.wantMessage)
			}
			var lastChatAt time.Time
			if rec.lastState != nil {
				lastChatAt = rec.lastState.Panes["primary"].LastChatAt
			}
			if len(tc.wantSay)+len(tc.wantMessage) == 0 {
				if !lastChatAt.IsZero() {
					t.Fatalf("excluded narration changed LastChatAt: %s", lastChatAt)
				}
			} else if want := time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC); !lastChatAt.Equal(want) {
				t.Fatalf("LastChatAt = %s, want %s", lastChatAt, want)
			}
		})
	}
}

func TestHookClaudeClearsAbandonedDisplayAtLifecycleBoundary(t *testing.T) {
	for _, action := range []string{"working", "done"} {
		t.Run(action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, "claude", "say", "qm-chat", map[string]interface{}{"message_id": "pending", "prompt_id": "p1", "index": 0, "delta": "partial"})
			payload := map[string]interface{}{"prompt_id": "p2"}
			if action == "done" {
				payload["prompt_id"] = "p1"
				payload["last_assistant_message"] = "complete final"
			}
			runHookWithStdin(r, "claude", action, "qm-chat", payload)
			pane := rec.lastState.Panes["primary"]
			if pane.ClaudeDisplayMessageID != "" || len(pane.ClaudeDisplayChunks) != 0 {
				t.Fatalf("pending display remained after %s: %+v", action, pane)
			}
		})
	}
}

func TestReadCodexCommentaryFiltersAndAdvancesOffset(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	appendCodexRollout(t, path, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"Checking layout"}}}`)
	appendCodexRollout(t, path, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"final_answer","text":"Done"}}}`)
	commentary, offset, _, err := readCodexCommentary(path, 0, false)
	if err != nil {
		t.Fatalf("read rollout: %v", err)
	}
	if !slices.Equal(commentary, []string{"Checking layout"}) {
		t.Fatalf("commentary = %q", commentary)
	}
	appendCodexRollout(t, path, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"Reading code"}}}`)
	commentary, next, _, err := readCodexCommentary(path, offset, false)
	if err != nil {
		t.Fatalf("read next rollout chunk: %v", err)
	}
	if !slices.Equal(commentary, []string{"Reading code"}) || next <= offset {
		t.Fatalf("incremental read = %q offset %d, previous %d", commentary, next, offset)
	}
	commentary, repeated, _, err := readCodexCommentary(path, next, false)
	if err != nil || len(commentary) != 0 || repeated != next {
		t.Fatalf("repeat read = %q offset %d err %v", commentary, repeated, err)
	}
}

func TestReadCodexCommentaryLongLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	line, err := json.Marshal(map[string]interface{}{"type": "event_msg", "payload": map[string]interface{}{
		"type": "item_completed", "item": map[string]interface{}{"type": "AgentMessage", "phase": "commentary", "text": strings.Repeat("x", 100_000)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, append(line, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	commentary, offset, _, err := readCodexCommentary(path, 0, false)
	gotTextLen := 0
	if len(commentary) == 1 {
		gotTextLen = len(commentary[0])
	}
	if err != nil || len(commentary) != 1 || gotTextLen != 100_000 || offset != int64(len(line)+1) {
		t.Fatalf("long line read = %d entries/%d chars offset=%d err=%v", len(commentary), gotTextLen, offset, err)
	}
}

func TestReadCodexCommentarySkipsOversizedLine(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	valid := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"after oversized line"}}}`
	contents := append([]byte(strings.Repeat("x", codexRolloutReadLimit+100)+"\n"), []byte(valid+"\n")...)
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	commentary, offset, skipping, err := readCodexCommentary(path, 0, false)
	if err != nil || len(commentary) != 0 || !skipping || offset != codexRolloutReadLimit {
		t.Fatalf("first oversized read = %q offset=%d skipping=%t err=%v", commentary, offset, skipping, err)
	}
	commentary, offset, skipping, err = readCodexCommentary(path, offset, skipping)
	if err != nil || !slices.Equal(commentary, []string{"after oversized line"}) || skipping || offset != int64(len(contents)) {
		t.Fatalf("oversized continuation = %q offset=%d skipping=%t err=%v", commentary, offset, skipping, err)
	}
}

func TestHookCodexRolloutPathChangeAndSubagentExclusion(t *testing.T) {
	first := filepath.Join(t.TempDir(), "first.jsonl")
	second := filepath.Join(t.TempDir(), "second.jsonl")
	child := filepath.Join(t.TempDir(), "child.jsonl")
	appendCodexRollout(t, first, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"old"}}}`)
	appendCodexRollout(t, second, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"new parent rollout"}}}`)
	appendCodexRollout(t, second, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"another narration"}}}`)
	appendCodexRollout(t, child, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"child text"}}}`)
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{SessionID: "qm-codex", Version: state.SchemaVersion, Panes: map[string]state.PaneState{
		"primary": {Role: "primary", Agent: "codex", CodexTranscriptPath: first, CodexTranscriptOffset: 10_000},
	}}
	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"transcript_path": second})
	var narration []string
	for _, entry := range chatEntries(rec.events[len(rec.events)-1]) {
		if entry["chat_kind"] == "say" {
			narration = append(narration, entry["chat_text"].(string))
		}
	}
	if !slices.Equal(narration, []string{"new parent rollout", "another narration"}) {
		t.Fatalf("path-change narration = %q", narration)
	}
	pane := rec.lastState.Panes["primary"]
	if pane.CodexTranscriptPath != second {
		t.Fatalf("stored path = %q, want %q", pane.CodexTranscriptPath, second)
	}
	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"agent_id": "task-1", "transcript_path": child})
	last := rec.events[len(rec.events)-1]
	if len(chatEntries(last)) != 0 || rec.lastState.Panes["primary"].CodexTranscriptPath != second {
		t.Fatalf("subagent rollout changed feed or offset: event=%+v pane=%+v", last, rec.lastState.Panes["primary"])
	}
}

func TestHookCodexRetriesWhenRolloutOffsetChangesDuringRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	first := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"already consumed"}}}`
	second := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"appended during overlap"}}}`
	appendCodexRollout(t, path, first)
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{SessionID: "qm-codex", Version: state.SchemaVersion, Panes: map[string]state.PaneState{
		"primary": {Role: "primary", Agent: "codex", CodexTranscriptPath: path},
	}}
	firstCommit := true
	r.Update = func(sessionID string, mutate func(*state.SessionState) bool) error {
		rec.updateCalls++
		if firstCommit {
			firstCommit = false
			pane := rec.lastState.Panes["primary"]
			pane.CodexTranscriptOffset = int64(len(first) + 1)
			rec.lastState.Panes["primary"] = pane
			appendCodexRollout(t, path, second)
		}
		if mutate(rec.lastState) {
			rec.writeCalls++
		}
		return nil
	}

	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"transcript_path": path})
	var narration []string
	for _, event := range rec.events {
		for _, entry := range chatEntries(event) {
			if entry["chat_kind"] == "say" {
				narration = append(narration, entry["chat_text"].(string))
			}
		}
	}
	if !slices.Equal(narration, []string{"appended during overlap"}) {
		t.Fatalf("overlapping hook narration = %q", narration)
	}
	if got := rec.lastState.Panes["primary"].CodexTranscriptOffset; got != int64(len(first+"\n"+second+"\n")) {
		t.Fatalf("stored offset = %d, want %d", got, len(first+"\n"+second+"\n"))
	}
}

func TestHookCodexMissingAndRotatedRollout(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rollout.jsonl")
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"transcript_path": path})
	if rec.lastState.Panes["primary"].CodexTranscriptPath != path {
		t.Fatalf("missing rollout path = %q", rec.lastState.Panes["primary"].CodexTranscriptPath)
	}
	appendCodexRollout(t, path, `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"first"}}}`)
	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"transcript_path": path})
	if got := chatTextFor(rec.events[len(rec.events)-1], "say"); got != "first" {
		t.Fatalf("first rollout narration = %q", got)
	}
	oldOffset := rec.lastState.Panes["primary"].CodexTranscriptOffset
	short := `{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","phase":"commentary","text":"new"}}}` + "\n"
	if err := os.WriteFile(path, []byte(short), 0o600); err != nil {
		t.Fatal(err)
	}
	if int64(len(short)) >= oldOffset {
		t.Fatalf("test setup failed: replacement size %d >= old offset %d", len(short), oldOffset)
	}
	runHookWithStdin(r, "codex", "tool_end", "qm-codex", map[string]interface{}{"transcript_path": path})
	if got := chatTextFor(rec.events[len(rec.events)-1], "say"); got != "new" {
		t.Fatalf("rotated rollout narration = %q", got)
	}
}

func appendCodexRollout(t *testing.T, path, line string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(line + "\n"); err != nil {
		f.Close()
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestHookClaudeTaskNotificationDoesNotExposePrompt(t *testing.T) {
	r, rec := newTestRunner(t)
	prompt := "<task-notification>private task details</task-notification>"
	runHookWithStdin(r, "claude", "working", "qm-chat", map[string]interface{}{"prompt": prompt})
	if got := rec.lastState.Panes["primary"].Activity; got != "Background agent resumed" {
		t.Fatalf("notification activity = %q", got)
	}
	if strings.Contains(rec.events[0].Activity, prompt) || strings.Contains(rec.events[0].Activity, "private task details") {
		t.Fatalf("task notification leaked in event: %+v", rec.events[0])
	}
}

func TestHookChatStatusDedupesAcrossStarting(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{SessionID: "qm-chat", Version: state.SchemaVersion, Panes: map[string]state.PaneState{
		"primary": {Role: "primary", Agent: "claude", State: "starting", LastChatStatus: "working"},
	}}
	for _, action := range []string{"working", "blocked", "blocked", "done"} {
		runHookWithStdin(r, "claude", action, "qm-chat", map[string]interface{}{"last_assistant_message": "finished"})
	}
	var statuses []string
	for _, event := range rec.events {
		for _, entry := range chatEntries(event) {
			if entry["chat_kind"] == "status" {
				status, _ := entry["chat_text"].(string)
				statuses = append(statuses, status)
			}
		}
	}
	if !slices.Equal(statuses, []string{"blocked", "done"}) {
		t.Fatalf("status feed = %v, want blocked then done (no duplicate working or idle)", statuses)
	}
}

type manifestStoreStub struct {
	manifest    state.Manifest
	readCalls   int
	updateCalls int
	readErr     error
	updateErr   error
}

func newManifestStoreStub(sessionID string, extras map[string]string) *manifestStoreStub {
	m := state.Manifest{SessionID: sessionID}
	for key, value := range extras {
		m.SetExtra(key, value)
	}
	return &manifestStoreStub{manifest: m}
}

func manifestHasExtra(m state.Manifest, key string) bool {
	_, ok := m.Extra[key]
	return ok
}

func (s *manifestStoreStub) Read(sessionID string) (state.Manifest, error) {
	s.readCalls++
	if s.readErr != nil {
		return state.Manifest{}, s.readErr
	}
	return s.manifest, nil
}

func (s *manifestStoreStub) Update(sessionID string, fn func(*state.Manifest)) error {
	s.updateCalls++
	if s.updateErr != nil {
		return s.updateErr
	}
	fn(&s.manifest)
	s.manifest.SessionID = sessionID
	return nil
}

type tmuxEnvCall struct {
	session string
	key     string
	value   string
}

type tmuxRenameCall struct {
	target string
	name   string
}

type tmuxPaneOptionCall struct {
	target string
	key    string
	value  string
}

type tmuxEnvStub struct {
	calls           []tmuxEnvCall
	renameCalls     []tmuxRenameCall
	paneOptionCalls []tmuxPaneOptionCall
	err             error
}

func (s *tmuxEnvStub) SetEnvironment(_ context.Context, session, key, value string) error {
	s.calls = append(s.calls, tmuxEnvCall{session: session, key: key, value: value})
	return s.err
}

func (s *tmuxEnvStub) RenameWindow(_ context.Context, target, name string) error {
	s.renameCalls = append(s.renameCalls, tmuxRenameCall{target: target, name: name})
	return s.err
}

func (s *tmuxEnvStub) SetPaneOption(_ context.Context, target, key, value string) error {
	s.paneOptionCalls = append(s.paneOptionCalls, tmuxPaneOptionCall{target: target, key: key, value: value})
	return s.err
}

func runHookWithStdin(r *HookRunner, agent, action, session string, payload interface{}) (stderr string) {
	var data []byte
	if payload != nil {
		data, _ = json.Marshal(payload)
	}
	var buf bytes.Buffer
	opts := hookOptions{agent: agent, action: action, session: session, stdin: data}
	runHook(r, opts, &buf)
	return buf.String()
}

type failOnRead struct{}

func (failOnRead) Read([]byte) (int, error) {
	return 0, errors.New("read should not be called")
}

func TestReadStdinNonBlockingSkipsInteractiveInput(t *testing.T) {
	orig := stdinLooksInteractive
	t.Cleanup(func() { stdinLooksInteractive = orig })
	stdinLooksInteractive = func(io.Reader) bool { return true }

	data, err := readStdinNonBlocking(failOnRead{})
	if err != nil {
		t.Fatalf("readStdinNonBlocking: %v", err)
	}
	if data != nil {
		t.Fatalf("data = %q, want nil for interactive stdin", data)
	}
}

func TestReadStdinNonBlockingReadsPipedInput(t *testing.T) {
	orig := stdinLooksInteractive
	t.Cleanup(func() { stdinLooksInteractive = orig })
	stdinLooksInteractive = func(io.Reader) bool { return false }

	data, err := readStdinNonBlocking(strings.NewReader("payload"))
	if err != nil {
		t.Fatalf("readStdinNonBlocking: %v", err)
	}
	if string(data) != "payload" {
		t.Fatalf("data = %q, want payload", data)
	}
}

func TestHookNoSessionExitsCleanly(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "", nil)
	if stderr != "" {
		t.Errorf("unexpected stderr: %q", stderr)
	}
	if rec.updateCalls != 0 || len(rec.events) != 0 {
		t.Errorf("no-session call should be a no-op, got updates=%d events=%d", rec.updateCalls, len(rec.events))
	}
}

func TestHookInvalidSessionIsRejected(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "../escape", nil)
	if !strings.Contains(stderr, "invalid QUESTMASTER_SESSION") {
		t.Errorf("expected invalid-session warning, got %q", stderr)
	}
	if rec.updateCalls != 0 {
		t.Errorf("invalid session must not touch state, got %d updates", rec.updateCalls)
	}
}

func TestHookAcceptsQMSessionIDs(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "qm-hook", nil)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if rec.updateCalls == 0 {
		t.Fatal("expected hook to update state")
	}
}

func TestHookSessionFromEnv(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-env")
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "", nil)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if rec.lastState == nil || rec.lastState.SessionID != "qm-env" {
		t.Fatalf("SessionID = %#v, want qm-env", rec.lastState)
	}
}

// TestHookStartingSnippetIsStarted pins the starting-state Activity snippet
// to "started" (not "starting…") for every agent. The tracker renders the
// state as "idle (started)" with the idle glyph, so the snippet has to
// match — anything else (the old ellipsis variant included) would either
// look like a stale pre-PR string or fight the new render.
func TestHookStartingSnippetIsStarted(t *testing.T) {
	cases := []struct {
		agent  string
		action string
	}{
		{agent: "claude", action: "starting"},
		{agent: "codex", action: "starting"},
		{agent: "pi", action: "session_start"},
		{agent: "pi", action: "before_agent_start"},
		{agent: "pi", action: "agent_start"},
	}
	for _, tc := range cases {
		t.Run(tc.agent+"/"+tc.action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			stderr := runHookWithStdin(r, tc.agent, tc.action, "qm-abc", nil)
			if stderr != "" {
				t.Fatalf("stderr: %q", stderr)
			}
			pane := rec.lastState.Panes["primary"]
			if pane.State != "starting" {
				t.Fatalf("state = %q, want starting", pane.State)
			}
			if pane.Activity != "started" {
				t.Fatalf("activity = %q, want %q", pane.Activity, "started")
			}
		})
	}
}

func TestHookClaudeStartingSetsState(t *testing.T) {
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if rec.updateCalls != 1 || rec.writeCalls != 1 {
		t.Errorf("want one update+write, got %d/%d", rec.updateCalls, rec.writeCalls)
	}
	pane := rec.lastState.Panes["primary"]
	if pane.State != "starting" || pane.Activity != "started" || pane.LastKind != "SessionStart" {
		t.Errorf("starting pane: %+v", pane)
	}
}

func TestHookClaudeStrayStartingDoesNotRegressWorkingPane(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "starting", "qm-abc", nil)
	runHookWithStdin(r, "claude", "working", "qm-abc", map[string]interface{}{"prompt": "do the thing"})
	if got := rec.lastState.Panes["primary"].State; got != "working" {
		t.Fatalf("setup: pane state = %q, want working", got)
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if got := rec.lastState.Panes["primary"].State; got != "working" {
		t.Errorf("stray SessionStart regressed pane state to %q, want working", got)
	}
}

func TestHookClaudeStartingAllowedAfterStopped(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "stopped", LastKind: "SessionEnd"},
		},
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if got := rec.lastState.Panes["primary"].State; got != "starting" {
		t.Errorf("genuine resume: pane state = %q, want starting", got)
	}
}

func TestHookClaudeUserPromptSubmit(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "working", "qm-abc", map[string]interface{}{
		"prompt": "What's the time?\nSecond line ignored",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("want state=working, got %q", pane.State)
	}
	if pane.Activity != "You: What's the time?" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.LastKind != "UserPromptSubmit" {
		t.Errorf("last_kind: %q", pane.LastKind)
	}
}

func TestHookClaudePreToolUseEdit(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Edit",
		"tool_input": map[string]interface{}{"file_path": "/long/path/to/foo.go"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "Edit: foo.go" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.Tool != "Edit" {
		t.Errorf("tool: %q", pane.Tool)
	}
	if pane.LastKind != "PreToolUse" {
		t.Errorf("last_kind: %q", pane.LastKind)
	}
}

func TestHookClaudePreToolUseBashStripsEnvAssignments(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Bash",
		"tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-xxx do-thing arg1 arg2"},
	})
	pane := rec.lastState.Panes["primary"]
	if strings.Contains(pane.Activity, "sk-xxx") {
		t.Errorf("leaked env value into Activity: %q", pane.Activity)
	}
	if !strings.HasPrefix(pane.Activity, "Bash: do-thing") {
		t.Errorf("unexpected activity: %q", pane.Activity)
	}
}

func TestHookClaudeToolStartWritesChatTimestamp(t *testing.T) {
	r, rec := newTestRunner(t)
	prior := time.Date(2026, 5, 20, 11, 59, 0, 0, time.UTC)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:         "primary",
				Agent:        "claude",
				State:        "working",
				Activity:     "Edit: foo.go",
				Tool:         "Edit",
				LastKind:     "PreToolUse",
				LastEvent:    prior,
				WorkingSince: prior,
			},
		},
	}

	stderr := runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Edit",
		"tool_input": map[string]interface{}{"file_path": "/tmp/foo.go"},
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if rec.updateCalls != 1 {
		t.Fatalf("updateCalls = %d, want 1", rec.updateCalls)
	}
	if rec.writeCalls != 1 {
		t.Fatalf("writeCalls = %d, want 1 for LastChatAt", rec.writeCalls)
	}
	if got := rec.lastState.Panes["primary"].LastChatAt; !got.Equal(r.Now()) {
		t.Fatalf("LastChatAt = %s, want %s", got, r.Now())
	}
	if len(rec.events) != 1 {
		t.Fatalf("events = %d, want 1", len(rec.events))
	}
}

func TestHookClaudePostToolUseDoesNotClobberActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	// Seed an in-flight Edit then post.
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", Tool: "Edit", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "tool_end", "qm-abc", map[string]interface{}{"tool_name": "Edit"})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "Edit: foo.go" {
		t.Errorf("PostToolUse clobbered activity: %q", pane.Activity)
	}
	if pane.Tool != "" {
		t.Errorf("PostToolUse did not clear Tool: %q", pane.Tool)
	}
	if pane.LastKind != "PostToolUse" {
		t.Errorf("PostToolUse did not update LastKind: %q", pane.LastKind)
	}
}

// TestHookClaudePostToolUseClearsStaleNotificationActivity simulates the
// production sequence: PreToolUse (working/"Edit: foo.go") → Notification
// (blocked/"Notification: …") → user grants permission → PostToolUse.
// The PreToolUse snippet is already lost (Notification overwrote it),
// so the pane must NOT keep showing "Notification: …" — clear it
// instead so the next PreToolUse / UserPromptSubmit can refill it.
func TestHookClaudePostToolUseClearsStaleNotificationActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Edit",
		"tool_input": map[string]interface{}{"file_path": "/repo/foo.go"},
	})
	runHookWithStdin(r, "claude", "blocked", "qm-abc", map[string]interface{}{
		"message": "Permission needed: edit /repo/foo.go",
	})
	pane := rec.lastState.Panes["primary"]
	if !strings.HasPrefix(pane.Activity, "Notification: ") {
		t.Fatalf("precondition: Notification did not overwrite Activity, got %q", pane.Activity)
	}
	runHookWithStdin(r, "claude", "tool_end", "qm-abc", map[string]interface{}{"tool_name": "Edit"})
	pane = rec.lastState.Panes["primary"]
	if pane.Activity != "" {
		t.Errorf("PostToolUse left stale Notification snippet: %q", pane.Activity)
	}
	if pane.State != "working" {
		t.Errorf("PostToolUse should flip State back to working, got %q", pane.State)
	}
	if pane.LastKind != "PostToolUse" {
		t.Errorf("PostToolUse did not update LastKind: %q", pane.LastKind)
	}
}

func TestHookClaudeStopReadsTranscriptTail(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done — let me know."}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "All done") {
		t.Errorf("activity: %q", pane.Activity)
	}
	if len(rec.transcriptPaths) == 0 {
		t.Error("transcript_path was not consulted")
	}
}

// TestHookClaudeStopPrefersLastAssistantMessage covers the regression
// where Claude's Stop fires before the transcript flush completes and
// saidSnippet returns "". The hook must read the payload's
// last_assistant_message field (mirrors the Codex pattern) and skip
// the transcript tail entirely when the payload field is populated.
func TestHookClaudeStopPrefersLastAssistantMessage(t *testing.T) {
	r, rec := newTestRunner(t)
	// Set a transcript tail that would otherwise win — this assertion
	// proves the payload field takes precedence.
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"transcript snippet"}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{
		"transcript_path":        "/tmp/whatever.jsonl",
		"last_assistant_message": "Why do Finns make great secret agents?",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "Why do Finns make great secret agents?" {
		t.Errorf("activity: %q, want 'Why do Finns make great secret agents?'", pane.Activity)
	}
}

// TestHookClaudeStopFallsBackToTranscriptTail asserts the transcript
// fallback still runs when the payload omits last_assistant_message.
func TestHookClaudeStopFallsBackToTranscriptTail(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.transcriptTail = []byte(`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"from transcript"}]}}` + "\n")
	runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "from transcript" {
		t.Errorf("activity: %q, want 'from transcript'", pane.Activity)
	}
	if len(rec.transcriptPaths) == 0 {
		t.Error("transcript_path was not consulted in fallback path")
	}
}

func TestHookClaudeStopWithMissingTranscriptStillSucceeds(t *testing.T) {
	r, rec := newTestRunner(t)
	// LoadTranscriptTail in newTestRunner returns rec.transcriptTail (nil by default).
	runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{"transcript_path": "/nope.jsonl"})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if pane.Activity != "" {
		t.Errorf("activity should be empty when transcript missing: %q", pane.Activity)
	}
}

func TestHookClaudeSubagentSuppressesParentState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", LastKind: "PreToolUse"},
		},
	}
	// Subagent Stop must not flip parent to done.
	runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{
		"agent_id":        "task-42",
		"transcript_path": "/tmp/whatever.jsonl",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent should not flip parent State: got %q", pane.State)
	}
	if pane.Activity != "Edit: foo.go" {
		t.Errorf("subagent done should not clobber parent Activity: got %q", pane.Activity)
	}
}

func TestHookClaudeSubagentToolEventDoesNotFlipAlreadyWorkingParentState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "old", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"agent_id":   "task-99",
		"tool_name":  "Read",
		"tool_input": map[string]interface{}{"file_path": "/x/y.go"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent tool_start on an already-working parent should not touch State: got %q", pane.State)
	}
	// Activity / Tool / LastKind still update so renderer can show what's happening.
	if pane.Activity != "Read: y.go" {
		t.Errorf("subagent activity not recorded: %q", pane.Activity)
	}
}

// TestHookClaudeSubagentToolEventRecoversParentStateFromIdle covers the
// Group C regression: once the parent has gone idle/done, a sub-agent's
// real tool activity must be able to flip the border back to working
// instead of leaving it stuck on the stale idle/done state.
func TestHookClaudeSubagentToolEventRecoversParentStateFromIdle(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "idle", Activity: "old", LastKind: "Stop"},
		},
	}
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"agent_id":   "task-99",
		"tool_name":  "Read",
		"tool_input": map[string]interface{}{"file_path": "/x/y.go"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent tool_start should recover parent State from idle to working: got %q", pane.State)
	}
	if pane.Activity != "Read: y.go" {
		t.Errorf("subagent activity not recorded: %q", pane.Activity)
	}
}

func TestHookClaudeSubagentStopUpdatesActivityOnly(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "subagent_stop", "qm-abc", map[string]interface{}{
		"agent_id": "task-42",
		"result":   "Reviewed 12 files.\nDetails follow…",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Errorf("subagent_stop should never change State, got %q", pane.State)
	}
	if pane.Activity != "Subagent: Reviewed 12 files." {
		t.Errorf("subagent_stop activity: %q", pane.Activity)
	}
	if pane.LastKind != "SubagentStop" {
		t.Errorf("subagent_stop LastKind: %q", pane.LastKind)
	}
}

func TestHookClaudeAskUserQuestionShowsQuestionSnippet(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name": "AskUserQuestion",
		"tool_input": map[string]interface{}{
			"questions": []interface{}{
				map[string]interface{}{
					"question": "What is your favorite color?",
					"header":   "Color",
				},
			},
		},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("state: %q, want blocked", pane.State)
	}
	if pane.Activity != "Question: What is your favorite color?" {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.Tool != "AskUserQuestion" {
		t.Errorf("tool: %q", pane.Tool)
	}
}

func TestHookClaudeAskUserQuestionNotificationPreservesQuestionActivity(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "blocked", Activity: "Question: What is your favorite color?", Tool: "AskUserQuestion", LastKind: "PreToolUse"},
		},
	}
	runHookWithStdin(r, "claude", "blocked", "qm-abc", map[string]interface{}{
		"message": "Claude needs your permission",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.Activity != "Question: What is your favorite color?" {
		t.Errorf("Notification clobbered Question activity: %q", pane.Activity)
	}
	if pane.State != "blocked" {
		t.Errorf("state: %q, want blocked", pane.State)
	}
}

func TestHookClaudeBlocked(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "blocked", "qm-abc", map[string]interface{}{
		"message": "Permission needed: edit /etc/hosts",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "Notification: Permission needed") {
		t.Errorf("activity: %q", pane.Activity)
	}
}

// TestStopReadsAssistantBeyond4KB enforces that the Stop tail is large
// enough to find an assistant message that sits past the original 4 KiB
// limit. Real Claude transcripts append many post-message metadata
// records, so the assistant message can land tens of KiB before EOF.
func TestStopReadsAssistantBeyond4KB(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "transcript.jsonl")
	f, err := os.Create(path)
	if err != nil {
		t.Fatalf("create transcript: %v", err)
	}
	// Assistant message first, then ~30 KiB of trailing metadata
	// records — total payload sits between the old 4 KiB tail and the
	// new 64 KiB tail.
	assistantLine := `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"All done — let me know."}]}}` + "\n"
	if _, err := f.WriteString(assistantLine); err != nil {
		t.Fatalf("write assistant: %v", err)
	}
	metaLine := `{"type":"system","kind":"attachment","payload":"` + strings.Repeat("x", 300) + `"}` + "\n"
	for i := 0; i < 100; i++ { // ~30 KiB of trailing metadata
		if _, err := f.WriteString(metaLine); err != nil {
			t.Fatalf("write meta: %v", err)
		}
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	setTestStateRoot(t)

	payload, _ := json.Marshal(map[string]interface{}{"transcript_path": path})
	var buf bytes.Buffer
	runHook(r, hookOptions{agent: "claude", action: "done", session: "qm-tail", stdin: payload}, &buf)
	if s := buf.String(); s != "" {
		t.Errorf("stderr: %q", s)
	}

	ss, err := state.LoadSessionState("qm-tail")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	pane := ss.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("state: %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "All done") {
		t.Errorf("activity: %q (assistant message not extracted from 64 KiB tail)", pane.Activity)
	}
}

// TestNotificationIdleDoesNotFlipState reproduces the false-positive
// flow from production logs: Stop fires (state=done), then ~60s later
// Claude fires Notification with "Claude is waiting for your input" —
// the agent is idle, not blocked. State must stay done.
func TestNotificationIdleDoesNotFlipState(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "claude", State: "done", Activity: "All done.", LastKind: "Stop"},
		},
	}
	runHookWithStdin(r, "claude", "blocked", "qm-abc", map[string]interface{}{
		"message": "Claude is waiting for your input",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "done" {
		t.Errorf("idle-waiting Notification should not flip State, got %q", pane.State)
	}
	if pane.Activity != "All done." {
		t.Errorf("idle-waiting Notification should not clobber Activity, got %q", pane.Activity)
	}
	if pane.LastKind != "Notification" {
		t.Errorf("LastKind should record the Notification arrived, got %q", pane.LastKind)
	}
}

// TestNotificationGenuineFlipsBlocked confirms permission/approval
// Notifications still produce state=blocked.
func TestNotificationGenuineFlipsBlocked(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "claude", "blocked", "qm-abc", map[string]interface{}{
		"message": "Permission required for X",
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Errorf("genuine Notification should flip blocked, got %q", pane.State)
	}
	if !strings.HasPrefix(pane.Activity, "Notification: Permission required") {
		t.Errorf("activity: %q", pane.Activity)
	}
	if pane.LastKind != "Notification" {
		t.Errorf("LastKind: %q", pane.LastKind)
	}
}

func TestHookClaudeUnknownActionWarnsButDoesNotPanic(t *testing.T) {
	r, rec := newTestRunner(t)
	stderr := runHookWithStdin(r, "claude", "no-such-action", "qm-abc", nil)
	if !strings.Contains(stderr, "unknown action") {
		t.Errorf("want unknown-action warning, got %q", stderr)
	}
	if rec.updateCalls != 0 {
		t.Error("unknown action should not write state")
	}
}

func TestHookClaudeTolerantPayload(t *testing.T) {
	r, _ := newTestRunner(t)
	// Garbage stdin: a non-JSON byte stream. The hook must still record
	// the event without panicking.
	opts := hookOptions{agent: "claude", action: "tool_start", session: "qm-abc", stdin: []byte("not json at all")}
	var buf bytes.Buffer
	runHook(r, opts, &buf)
	// Either silently tolerated or warning emitted — both acceptable.
	// What's NOT acceptable is a panic, which would fail the test
	// outright via recover-less crash.
}

func TestHookClaudeCapturesSessionIDInManifest(t *testing.T) {
	t.Setenv("CLAUDE_SESSION_ID", "")
	root := setTestStateRoot(t)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-abc"}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	r.LoadTranscriptTail = func(string) ([]byte, error) { return nil, nil }
	r.TmuxClient = &tmuxEnvStub{}
	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}

	m, err := store.Read("qm-abc")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := m.ExtraString("claude_session_id"); got != "claude-session-1" {
		t.Fatalf("claude_session_id: got %q, want %q", got, "claude-session-1")
	}
}

func TestHookClaudeSessionIDMatchesExistingSkipsManifestWrite(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "claude-session-1")
	store := newManifestStoreStub("qm-abc", map[string]string{"claude_session_id": "claude-session-1"})
	store.manifest.Agents = []state.AgentManifest{{
		Name: "claude", Role: "primary", CLI: "claude", ResumeID: "claude-session-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "working", "qm-abc", map[string]interface{}{
		"prompt":     "continue",
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.readCalls != 1 {
		t.Fatalf("manifest reads: got %d, want 1", store.readCalls)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest update should be skipped when unchanged, got %d updates", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookClaudeSessionIDDifferentUpdatesManifest(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", map[string]string{"claude_session_id": "old-session"})
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	stderr := runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Read",
		"tool_input": map[string]interface{}{"file_path": "/tmp/file.go"},
		"session_id": "new-session",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "new-session" {
		t.Fatalf("claude_session_id: got %q, want %q", got, "new-session")
	}
}

func TestHookClaudeNoSessionIDLeavesManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.readCalls != 0 || store.updateCalls != 0 {
		t.Fatalf("manifest should be untouched, reads=%d updates=%d", store.readCalls, store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 {
		t.Fatalf("tmux env should be untouched, got %+v", tmuxEnv.calls)
	}
}

func TestHookClaudeManifestWriteFailureStillCompletes(t *testing.T) {
	r, rec := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	store.updateErr = errors.New("disk full")
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if !strings.Contains(stderr, "update manifest") {
		t.Fatalf("expected manifest update warning, got %q", stderr)
	}
	if len(rec.events) != 1 {
		t.Fatalf("event log writes: got %d, want 1", len(rec.events))
	}
	if rec.lastState == nil || rec.lastState.Panes["primary"].State != "starting" {
		t.Fatalf("state update did not complete: %+v", rec.lastState)
	}
}

func TestHookClaudeTmuxEnvFailureStillCompletes(t *testing.T) {
	r, rec := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{err: errors.New("tmux unavailable")}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if !strings.Contains(stderr, "set tmux env") {
		t.Fatalf("expected tmux env warning, got %q", stderr)
	}
	if len(rec.events) != 1 {
		t.Fatalf("event log writes: got %d, want 1", len(rec.events))
	}
	if rec.lastState == nil || rec.lastState.Panes["primary"].State != "starting" {
		t.Fatalf("state update did not complete: %+v", rec.lastState)
	}
}

func TestCaptureResumeIDFirstEventWritesManifestAndTmuxEnv(t *testing.T) {
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r := &HookRunner{Store: store, TmuxClient: tmuxEnv}

	var stderr bytes.Buffer
	captureResumeID(context.Background(), r, &stderr, "qm-abc", "claude_session_id", "CLAUDE_SESSION_ID", "claude-session-1", "claude")

	if stderr.String() != "" {
		t.Fatalf("stderr: %q", stderr.String())
	}
	if store.readCalls != 1 {
		t.Fatalf("manifest reads: got %d, want 1", store.readCalls)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "claude-session-1" {
		t.Fatalf("claude_session_id: got %q, want %q", got, "claude-session-1")
	}
	if len(tmuxEnv.calls) != 1 || tmuxEnv.calls[0] != (tmuxEnvCall{session: "qm-abc", key: "CLAUDE_SESSION_ID", value: "claude-session-1"}) {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestCaptureResumeIDCurrentEnvPersistsMissingManifestAndSkipsTmuxEnv(t *testing.T) {
	t.Setenv("CLAUDE_SESSION_ID", "claude-session-1")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r := &HookRunner{Store: store, TmuxClient: tmuxEnv}

	var stderr bytes.Buffer
	captureResumeID(context.Background(), r, &stderr, "qm-abc", "claude_session_id", "CLAUDE_SESSION_ID", "claude-session-1", "claude")

	if stderr.String() != "" {
		t.Fatalf("stderr: %q", stderr.String())
	}
	if store.readCalls != 1 {
		t.Fatalf("manifest reads: got %d, want 1", store.readCalls)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "claude-session-1" {
		t.Fatalf("claude_session_id: got %q, want %q", got, "claude-session-1")
	}
	if len(tmuxEnv.calls) != 0 {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestCaptureResumeIDPersistedManifestSkipsSecondTmuxEnv(t *testing.T) {
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r := &HookRunner{Store: store, TmuxClient: tmuxEnv}

	var stderr bytes.Buffer
	captureResumeID(context.Background(), r, &stderr, "qm-abc", "claude_session_id", "CLAUDE_SESSION_ID", "claude-session-1", "claude")
	captureResumeID(context.Background(), r, &stderr, "qm-abc", "claude_session_id", "CLAUDE_SESSION_ID", "claude-session-1", "claude")

	if stderr.String() != "" {
		t.Fatalf("stderr: %q", stderr.String())
	}
	if store.readCalls != 2 {
		t.Fatalf("manifest reads: got %d, want 2", store.readCalls)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 1 {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookClaudeSessionStartAdoptsAgentlessManifestAndTagsPane(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Cwd = "/old"
	adoptedCwd := t.TempDir()
	t.Chdir(adoptedCwd)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	payload := map[string]interface{}{"session_id": "claude-session-1"}
	if stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", payload); stderr != "" {
		t.Fatalf("first stderr: %q", stderr)
	}
	if stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", payload); stderr != "" {
		t.Fatalf("second stderr: %q", stderr)
	}

	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if len(store.manifest.Agents) != 1 {
		t.Fatalf("agents = %+v, want one adopted agent", store.manifest.Agents)
	}
	agent := store.manifest.Agents[0]
	if agent.Name != "claude" || agent.Role != "primary" || agent.CLI != "claude" ||
		agent.ResumeID != "claude-session-1" || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("adopted agent = %+v", agent)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "claude-session-1" {
		t.Fatalf("claude_session_id: got %q, want claude-session-1", got)
	}
	if store.manifest.Cwd != adoptedCwd {
		t.Fatalf("adopted cwd = %q, want %q", store.manifest.Cwd, adoptedCwd)
	}
	if got := store.manifest.ExtraString("adopted_pane"); got != "%7" {
		t.Fatalf("adopted_pane: got %q, want %%7", got)
	}
	if len(tmuxEnv.paneOptionCalls) != 1 || tmuxEnv.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%7", key: tmux.PaneRoleOption, value: tmux.RolePrimary}) {
		t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
	}
	if len(tmuxEnv.calls) != 1 || tmuxEnv.calls[0] != (tmuxEnvCall{session: "qm-abc", key: "CLAUDE_SESSION_ID", value: "claude-session-1"}) {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookClaudeAdoptsAgentlessManifestWithoutPaneTagOutsideTmux(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if len(store.manifest.Agents) != 1 || store.manifest.Agents[0].Name != "claude" {
		t.Fatalf("agents = %+v, want adopted claude", store.manifest.Agents)
	}
	if !manifestHasExtra(store.manifest, "adopted_pane") || store.manifest.ExtraString("adopted_pane") != "" {
		t.Fatalf("adopted_pane should be recorded empty outside tmux, extras=%+v", store.manifest.Extra)
	}
	if len(tmuxEnv.paneOptionCalls) != 0 {
		t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
	}
}

func TestHookClaudeLeavesPersistedAgentManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", map[string]string{"claude_session_id": "claude-session-1"})
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "claude", Role: "primary", CLI: "claude", ResumeID: "claude-session-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxEnv.paneOptionCalls) != 0 {
		t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
	}
}

func TestHookClaudeExistingAgentDoesNotRehomeCwd(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	store := newManifestStoreStub("qm-abc", map[string]string{"claude_session_id": "old-session"})
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "claude", Role: "primary", CLI: "claude", ResumeID: "old-session", Window: tmux.WindowWorkspace,
	}}
	adoptedCwd := t.TempDir()
	t.Chdir(adoptedCwd)
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "new-session",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.manifest.Cwd != "/old" {
		t.Fatalf("existing agent cwd = %q, want /old", store.manifest.Cwd)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "new-session" {
		t.Fatalf("claude_session_id: got %q, want new-session", got)
	}
}

func TestHookClaudeLeavesDifferentAgentManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 || len(tmuxEnv.paneOptionCalls) != 0 {
		t.Fatalf("tmux calls: env=%+v pane=%+v", tmuxEnv.calls, tmuxEnv.paneOptionCalls)
	}
}

func TestHookAdoptedSessionSamePaneSuccession(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", map[string]string{
		"adopted_pane":    "%7",
		"codex_thread_id": "codex-thread-1",
	})
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	newCwd := t.TempDir()
	t.Chdir(newCwd)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}

	if len(store.manifest.Agents) != 1 {
		t.Fatalf("agents = %+v, want one successor", store.manifest.Agents)
	}
	agent := store.manifest.Agents[0]
	if agent.Name != "claude" || agent.Role != "primary" || agent.CLI != "claude" ||
		agent.ResumeID != "claude-session-1" || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("successor agent = %+v", agent)
	}
	if store.manifest.Cwd != newCwd {
		t.Fatalf("cwd = %q, want %q", store.manifest.Cwd, newCwd)
	}
	if got := store.manifest.ExtraString("adopted_pane"); got != "%7" {
		t.Fatalf("adopted_pane: got %q, want %%7", got)
	}
	if got := store.manifest.ExtraString("claude_session_id"); got != "claude-session-1" {
		t.Fatalf("claude_session_id: got %q, want claude-session-1", got)
	}
	if got := store.manifest.ExtraString("title_provisional"); got != "1" {
		t.Fatalf("title_provisional: got %q, want 1", got)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 1 || tmuxEnv.calls[0] != (tmuxEnvCall{session: "qm-abc", key: "CLAUDE_SESSION_ID", value: "claude-session-1"}) {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookAdoptedSessionDifferentPaneDoesNotSucceed(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%8")
	store := newManifestStoreStub("qm-abc", map[string]string{"adopted_pane": "%7"})
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 || len(tmuxEnv.paneOptionCalls) != 0 {
		t.Fatalf("tmux calls: env=%+v pane=%+v", tmuxEnv.calls, tmuxEnv.paneOptionCalls)
	}
}

func TestHookSpawnedSessionSamePaneForeignAgentDoesNotSucceed(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Cwd = "/old"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv
	before, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal before: %v", err)
	}

	stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	after, err := json.Marshal(store.manifest)
	if err != nil {
		t.Fatalf("marshal after: %v", err)
	}
	if !bytes.Equal(after, before) {
		t.Fatalf("manifest changed\nbefore: %s\nafter:  %s", before, after)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 || len(tmuxEnv.paneOptionCalls) != 0 {
		t.Fatalf("tmux calls: env=%+v pane=%+v", tmuxEnv.calls, tmuxEnv.paneOptionCalls)
	}
}

func TestHookAdoptedSessionSuccessorSecondEventSkipsManifestWork(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CLAUDE_SESSION_ID", "")
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", map[string]string{"adopted_pane": "%7"})
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv
	payload := map[string]interface{}{"session_id": "claude-session-1"}

	if stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", payload); stderr != "" {
		t.Fatalf("first stderr: %q", stderr)
	}
	if stderr := runHookWithStdin(r, "claude", "starting", "qm-abc", payload); stderr != "" {
		t.Fatalf("second stderr: %q", stderr)
	}

	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want one succession update", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 1 {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookClaudeSessionEndPreservesLockedTitle(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", map[string]string{"adopted_pane": "%7", "title_locked": "1"})
	store.manifest.Title = "Old title"
	store.manifest.WindowName = "party (Old title)"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "claude", Role: "primary", CLI: "claude", ResumeID: "claude-session-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "stopped", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if len(store.manifest.Agents) != 0 {
		t.Fatalf("agents = %+v, want cleared", store.manifest.Agents)
	}
	if manifestHasExtra(store.manifest, "adopted_pane") {
		t.Fatalf("adopted_pane should be cleared, extras=%+v", store.manifest.Extra)
	}
	if store.manifest.Title != "Old title" {
		t.Fatalf("title = %q, want Old title", store.manifest.Title)
	}
	if store.manifest.WindowName != "" {
		t.Fatalf("window_name = %q, want blank", store.manifest.WindowName)
	}
	if got := store.manifest.ExtraString("title_provisional"); got != "" {
		t.Fatalf("title_provisional: got %q, want cleared", got)
	}
	if got := store.manifest.ExtraString("title_locked"); got != "1" {
		t.Fatalf("title_locked: got %q, want 1", got)
	}
	if store.readCalls != 1 {
		t.Fatalf("manifest reads: got %d, want 1", store.readCalls)
	}
	if len(tmuxEnv.paneOptionCalls) != 1 || tmuxEnv.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%7", key: tmux.PaneRoleOption, value: tmux.RoleShell}) {
		t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
	}
	if len(tmuxEnv.renameCalls) != 0 {
		t.Fatalf("rename calls: %+v", tmuxEnv.renameCalls)
	}
}

func TestHookClaudeSessionEndDoesNotClearSpawnedAgent(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("TMUX_PANE", "%7")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Title = "Old title"
	store.manifest.WindowName = "party (Old title)"
	store.manifest.Agents = []state.AgentManifest{{
		Name: "claude", Role: "primary", CLI: "claude", ResumeID: "claude-session-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "claude", "stopped", "qm-abc", map[string]interface{}{
		"session_id": "claude-session-1",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if len(store.manifest.Agents) != 1 || store.manifest.Agents[0].Name != "claude" {
		t.Fatalf("agents = %+v, want untouched claude", store.manifest.Agents)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest updates: got %d, want 0", store.updateCalls)
	}
	if store.manifest.Title != "Old title" || store.manifest.WindowName != "party (Old title)" {
		t.Fatalf("title/window changed: title=%q window=%q", store.manifest.Title, store.manifest.WindowName)
	}
	if len(tmuxEnv.paneOptionCalls) != 0 || len(tmuxEnv.renameCalls) != 0 {
		t.Fatalf("tmux calls: pane=%+v rename=%+v", tmuxEnv.paneOptionCalls, tmuxEnv.renameCalls)
	}
}

func TestHookPiStyleSessionShutdownClearsAdoptedAgent(t *testing.T) {
	for _, agentName := range []string{"pi"} {
		t.Run(agentName, func(t *testing.T) {
			r, _ := newTestRunner(t)
			t.Setenv("TMUX_PANE", "%7")
			store := newManifestStoreStub("qm-abc", map[string]string{"adopted_pane": "%7"})
			store.manifest.Title = "Old title"
			store.manifest.WindowName = "party (Old title)"
			store.manifest.Agents = []state.AgentManifest{{
				Name: agentName, Role: "primary", CLI: agentName, ResumeID: agentName + "-session-1", Window: tmux.WindowWorkspace,
			}}
			tmuxEnv := &tmuxEnvStub{}
			r.Store = store
			r.TmuxClient = tmuxEnv

			stderr := runHookWithStdin(r, agentName, "session_shutdown", "qm-abc", nil)
			if stderr != "" {
				t.Fatalf("stderr: %q", stderr)
			}
			if len(store.manifest.Agents) != 0 {
				t.Fatalf("agents = %+v, want cleared", store.manifest.Agents)
			}
			if manifestHasExtra(store.manifest, "adopted_pane") {
				t.Fatalf("adopted_pane should be cleared, extras=%+v", store.manifest.Extra)
			}
			if store.manifest.Title != "Shell" || store.manifest.WindowName != "" {
				t.Fatalf("title/window = %q/%q, want Shell/blank", store.manifest.Title, store.manifest.WindowName)
			}
			if got := store.manifest.ExtraString("title_provisional"); got != "1" {
				t.Fatalf("title_provisional: got %q, want 1", got)
			}
			if len(tmuxEnv.paneOptionCalls) != 1 || tmuxEnv.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%7", key: tmux.PaneRoleOption, value: tmux.RoleShell}) {
				t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
			}
			if len(tmuxEnv.renameCalls) != 0 {
				t.Fatalf("rename calls: %+v", tmuxEnv.renameCalls)
			}
		})
	}
}

func TestHookCodexCapturesThreadIDInManifest(t *testing.T) {
	t.Setenv("CODEX_THREAD_ID", "codex-thread-1")
	root := setTestStateRoot(t)
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-abc"}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	r.LoadTranscriptTail = func(string) ([]byte, error) { return nil, nil }
	r.TmuxClient = &tmuxEnvStub{}
	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}

	m, err := store.Read("qm-abc")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := m.ExtraString("codex_thread_id"); got != "codex-thread-1" {
		t.Fatalf("codex_thread_id: got %q, want %q", got, "codex-thread-1")
	}
}

func TestHookCodexAdoptsAgentlessManifestFromThreadID(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "")
	t.Setenv("TMUX_PANE", "%8")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	resumeID := "019e7173-dce6-7951-a780-ec5331cd9ca9"
	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", map[string]interface{}{
		"thread_id": resumeID,
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if len(store.manifest.Agents) != 1 {
		t.Fatalf("agents = %+v, want one adopted agent", store.manifest.Agents)
	}
	agent := store.manifest.Agents[0]
	if agent.Name != "codex" || agent.Role != "primary" || agent.CLI != "codex" ||
		agent.ResumeID != resumeID || agent.Window != tmux.WindowWorkspace {
		t.Fatalf("adopted agent = %+v", agent)
	}
	if got := store.manifest.ExtraString("codex_thread_id"); got != resumeID {
		t.Fatalf("codex_thread_id: got %q, want %q", got, resumeID)
	}
	if len(tmuxEnv.paneOptionCalls) != 1 || tmuxEnv.paneOptionCalls[0] != (tmuxPaneOptionCall{target: "%8", key: tmux.PaneRoleOption, value: tmux.RolePrimary}) {
		t.Fatalf("pane option calls: %+v", tmuxEnv.paneOptionCalls)
	}
}

func TestHookCodexCapturesThreadIDFromPayloadSessionID(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "primary"}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	resumeID := "019e7173-dce6-7951-a780-ec5331cd9ca9"
	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", map[string]interface{}{
		"session_id": resumeID,
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if got := store.manifest.ExtraString("codex_thread_id"); got != resumeID {
		t.Fatalf("codex_thread_id: got %q, want %q", got, resumeID)
	}
	if got := manifestResumeID(store.manifest.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if len(tmuxEnv.calls) != 1 || tmuxEnv.calls[0] != (tmuxEnvCall{session: "qm-abc", key: "CODEX_THREAD_ID", value: resumeID}) {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookCodexCapturesThreadIDFromTranscriptPathWhenEnvUnset(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	store.manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "primary"}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	resumeID := "019e7173-dce6-7951-a780-ec5331cd9ca9"
	stderr := runHookWithStdin(r, "codex", "working", "qm-abc", map[string]interface{}{
		"prompt":          "continue",
		"transcript_path": "/Users/aleksi.tuominen/.codex/sessions/2026/05/29/rollout-2026-05-29T10-57-59-" + resumeID + ".jsonl",
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if got := store.manifest.ExtraString("codex_thread_id"); got != resumeID {
		t.Fatalf("codex_thread_id: got %q, want %q", got, resumeID)
	}
	if got := manifestResumeID(store.manifest.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if len(tmuxEnv.calls) != 1 || tmuxEnv.calls[0] != (tmuxEnvCall{session: "qm-abc", key: "CODEX_THREAD_ID", value: resumeID}) {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookCodexThreadIDMatchesExistingSkipsManifestWrite(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "codex-thread-1")
	store := newManifestStoreStub("qm-abc", map[string]string{"codex_thread_id": "codex-thread-1"})
	store.manifest.Agents = []state.AgentManifest{{
		Name: "codex", Role: "primary", CLI: "codex", ResumeID: "codex-thread-1", Window: tmux.WindowWorkspace,
	}}
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "codex", "working", "qm-abc", map[string]interface{}{"prompt": "continue"})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.readCalls != 1 {
		t.Fatalf("manifest reads: got %d, want 1", store.readCalls)
	}
	if store.updateCalls != 0 {
		t.Fatalf("manifest update should be skipped when unchanged, got %d updates", store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 {
		t.Fatalf("tmux env calls: %+v", tmuxEnv.calls)
	}
}

func TestHookCodexThreadIDDifferentUpdatesManifest(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "new-thread")
	store := newManifestStoreStub("qm-abc", map[string]string{"codex_thread_id": "old-thread"})
	r.Store = store
	r.TmuxClient = &tmuxEnvStub{}

	stderr := runHookWithStdin(r, "codex", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name":  "Read",
		"tool_input": map[string]interface{}{"file_path": "/tmp/file.go"},
	})
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.updateCalls != 1 {
		t.Fatalf("manifest updates: got %d, want 1", store.updateCalls)
	}
	if got := store.manifest.ExtraString("codex_thread_id"); got != "new-thread" {
		t.Fatalf("codex_thread_id: got %q, want %q", got, "new-thread")
	}
}

func TestHookCodexThreadIDUnsetLeavesManifestUntouched(t *testing.T) {
	r, _ := newTestRunner(t)
	t.Setenv("CODEX_THREAD_ID", "")
	store := newManifestStoreStub("qm-abc", nil)
	tmuxEnv := &tmuxEnvStub{}
	r.Store = store
	r.TmuxClient = tmuxEnv

	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Fatalf("stderr: %q", stderr)
	}
	if store.readCalls != 0 || store.updateCalls != 0 {
		t.Fatalf("manifest should be untouched, reads=%d updates=%d", store.readCalls, store.updateCalls)
	}
	if len(tmuxEnv.calls) != 0 {
		t.Fatalf("tmux env should be untouched, got %+v", tmuxEnv.calls)
	}
}

func TestHookCodexEndToEnd(t *testing.T) {
	r, rec := newTestRunner(t)
	for _, step := range []struct {
		name         string
		action       string
		payload      map[string]interface{}
		wantState    string
		wantActivity string
		wantTool     string
		wantKind     string
	}{
		{
			name:         "session start",
			action:       "starting",
			payload:      map[string]interface{}{"hook_event_name": "SessionStart"},
			wantState:    "starting",
			wantActivity: "started",
			wantKind:     "SessionStart",
		},
		{
			name:         "user prompt",
			action:       "working",
			payload:      map[string]interface{}{"hook_event_name": "UserPromptSubmit", "prompt": "What changed?\nignore"},
			wantState:    "working",
			wantActivity: "You: What changed?",
			wantKind:     "UserPromptSubmit",
		},
		{
			name:         "pre tool",
			action:       "tool_start",
			payload:      map[string]interface{}{"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-test echo hi"}},
			wantState:    "working",
			wantActivity: "Bash: echo hi",
			wantTool:     "Bash",
			wantKind:     "PreToolUse",
		},
		{
			name:         "post tool",
			action:       "tool_end",
			payload:      map[string]interface{}{"hook_event_name": "PostToolUse", "tool_name": "Bash"},
			wantState:    "working",
			wantActivity: "Bash: echo hi",
			wantKind:     "PostToolUse",
		},
		{
			name:         "stop",
			action:       "done",
			payload:      map[string]interface{}{"hook_event_name": "Stop", "agent_id": "ignored-by-codex", "last_assistant_message": "All set.\nignore"},
			wantState:    "done",
			wantActivity: "All set.",
			wantKind:     "Stop",
		},
	} {
		stderr := runHookWithStdin(r, "codex", step.action, "qm-abc", step.payload)
		if stderr != "" {
			t.Fatalf("%s stderr: %q", step.name, stderr)
		}
		pane := rec.lastState.Panes["primary"]
		if pane.State != step.wantState {
			t.Errorf("%s state: want %q got %q", step.name, step.wantState, pane.State)
		}
		if pane.Activity != step.wantActivity {
			t.Errorf("%s activity: want %q got %q", step.name, step.wantActivity, pane.Activity)
		}
		if pane.Tool != step.wantTool {
			t.Errorf("%s tool: want %q got %q", step.name, step.wantTool, pane.Tool)
		}
		if pane.LastKind != step.wantKind {
			t.Errorf("%s last_kind: want %q got %q", step.name, step.wantKind, pane.LastKind)
		}
	}
	if len(rec.events) != 5 {
		t.Fatalf("events: want 5 got %d", len(rec.events))
	}
	for _, ev := range rec.events {
		if ev.Agent != "codex" {
			t.Errorf("event agent: %+v", ev)
		}
	}
}

func TestHookCodexStrayStartingDoesNotRegressWorkingPane(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "codex", "starting", "qm-abc", nil)
	runHookWithStdin(r, "codex", "working", "qm-abc", map[string]interface{}{"prompt": "do the thing"})
	if got := rec.lastState.Panes["primary"].State; got != "working" {
		t.Fatalf("setup: pane state = %q, want working", got)
	}

	// Codex re-fires SessionStart mid-task (e.g. around compaction/reconnect);
	// it must not flap an active pane back to "starting".
	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if got := rec.lastState.Panes["primary"].State; got != "working" {
		t.Errorf("stray SessionStart regressed pane state to %q, want working", got)
	}
}

func TestHookCodexStartingAllowedAfterDone(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {Role: "primary", Agent: "codex", State: "done", LastKind: "Stop"},
		},
	}

	// A genuine resume of a finished session must still be able to move the
	// pane off "done" — continue.go doesn't reset PaneState.State on resume.
	stderr := runHookWithStdin(r, "codex", "starting", "qm-abc", nil)
	if stderr != "" {
		t.Errorf("stderr: %q", stderr)
	}
	if got := rec.lastState.Panes["primary"].State; got != "starting" {
		t.Errorf("genuine resume: pane state = %q, want starting", got)
	}
}

func TestHookCodexPermissionRequestBlocked(t *testing.T) {
	tests := []struct {
		name    string
		payload map[string]interface{}
		want    string
	}{
		{
			name: "message",
			payload: map[string]interface{}{
				"message":    "Allow Codex to run this command?\nsecond line",
				"permission": "ignored because message wins",
			},
			want: "Permission: Allow Codex to run this command?",
		},
		{
			name: "tool input command",
			payload: map[string]interface{}{
				"tool_input": map[string]interface{}{"command": "OPENAI_API_KEY=sk-test git status --short"},
			},
			want: "Permission: git status --short",
		},
		{
			name:    "permission fallback",
			payload: map[string]interface{}{"permission": "approval required"},
			want:    "Permission: approval required",
		},
		{
			name:    "generic fallback",
			payload: map[string]interface{}{},
			want:    "Permission: Permission required",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			stderr := runHookWithStdin(r, "codex", "permission", "qm-abc", tt.payload)
			if stderr != "" {
				t.Fatalf("stderr: %q", stderr)
			}
			pane := rec.lastState.Panes["primary"]
			if pane.State != "blocked" {
				t.Errorf("state: %q", pane.State)
			}
			if pane.Activity != tt.want {
				t.Errorf("activity: want %q got %q", tt.want, pane.Activity)
			}
			if !strings.HasPrefix(pane.Activity, "Permission: ") {
				t.Errorf("activity should start with Permission: got %q", pane.Activity)
			}
			if pane.LastKind != "PermissionRequest" {
				t.Errorf("last_kind: %q", pane.LastKind)
			}
		})
	}
}

func TestHookCodexRequestUserInputBlocksWithQuestion(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "codex", "tool_start", "qm-abc", map[string]interface{}{
		"tool_name": "functions.request_user_input",
		"tool_input": map[string]interface{}{
			"questions": []interface{}{
				map[string]interface{}{
					"question": "Pick a deployment target\nignored",
					"header":   "Deploy",
				},
			},
		},
	})

	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Fatalf("state: want %q, got %+v", "blocked", pane)
	}
	if pane.Activity != "Question: Pick a deployment target" {
		t.Fatalf("activity: want %q, got %q", "Question: Pick a deployment target", pane.Activity)
	}
	if pane.Tool != "functions.request_user_input" {
		t.Fatalf("tool: want %q, got %q", "functions.request_user_input", pane.Tool)
	}
	if pane.LastKind != "PreToolUse" {
		t.Fatalf("last_kind: want %q, got %q", "PreToolUse", pane.LastKind)
	}

	ev := rec.events[len(rec.events)-1]
	if ev.State != "blocked" || ev.Activity != "Question: Pick a deployment target" {
		t.Fatalf("event should carry blocked question, got %+v", ev)
	}
}

func TestHookCodexRequestUserInputToolEndClearsQuestion(t *testing.T) {
	r, rec := newTestRunner(t)
	rec.lastState = &state.SessionState{
		SessionID: "qm-abc",
		Version:   state.SchemaVersion,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:     "primary",
				Agent:    "codex",
				State:    "blocked",
				Activity: "Question: Pick a deployment target",
				Tool:     "functions.request_user_input",
				LastKind: "PreToolUse",
			},
		},
	}

	runHookWithStdin(r, "codex", "tool_end", "qm-abc", map[string]interface{}{"tool_name": "functions.request_user_input"})

	pane := rec.lastState.Panes["primary"]
	if pane.State != "working" {
		t.Fatalf("state: want %q, got %+v", "working", pane)
	}
	if pane.Activity != "" {
		t.Fatalf("activity should clear stale question, got %q", pane.Activity)
	}
	if pane.Tool != "" {
		t.Fatalf("tool should clear after tool_end, got %q", pane.Tool)
	}
	if pane.LastKind != "PostToolUse" {
		t.Fatalf("last_kind: want %q, got %q", "PostToolUse", pane.LastKind)
	}
}

func TestPiPromptActivityUsesUserPrefix(t *testing.T) {
	if got := piPromptActivity(piPayload{Prompt: "Fix this\nignore"}); got != "You: Fix this" {
		t.Fatalf("prompt activity: want %q, got %q", "You: Fix this", got)
	}
	if got := piPromptActivity(piPayload{Text: "Fallback text"}); got != "You: Fallback text" {
		t.Fatalf("text activity: want %q, got %q", "You: Fallback text", got)
	}
	if got := piPromptActivity(piPayload{}); got != "" {
		t.Fatalf("empty prompt activity: want empty, got %q", got)
	}
}

func TestPiToolActivityUsesClaudeVocabulary(t *testing.T) {
	tests := []struct {
		name    string
		payload piPayload
		want    string
	}{
		{
			name:    "edit",
			payload: piPayload{ToolName: "write", Args: map[string]interface{}{"path": "/tmp/foo.go"}},
			want:    "Edit: foo.go",
		},
		{
			name:    "apply patch",
			payload: piPayload{ToolName: "apply_patch", Args: map[string]interface{}{"file_path": "/tmp/patch.go"}},
			want:    "Edit: patch.go",
		},
		{
			name:    "read from summary",
			payload: piPayload{Tool: piToolPayload{Name: "read", Summary: "read: /tmp/bar.md"}},
			want:    "Read: bar.md",
		},
		{
			name:    "bash",
			payload: piPayload{Name: "shell", Arguments: map[string]interface{}{"cmd": "OPENAI_API_KEY=sk-test echo hi"}},
			want:    "Bash: echo hi",
		},
		{
			name:    "agent",
			payload: piPayload{ToolNameSnake: "Task", Input: map[string]interface{}{"description": "check this\nignore"}},
			want:    "Agent: check this",
		},
		{
			name:    "search",
			payload: piPayload{Tool: piToolPayload{ToolName: "grep"}, Args: map[string]interface{}{"pattern": "needle\nignore"}},
			want:    "Search: needle",
		},
		{
			name:    "unknown raw name",
			payload: piPayload{Name: "custom_tool", Args: map[string]interface{}{"query": "ignored"}},
			want:    "custom_tool",
		},
		{
			name:    "summary fallback",
			payload: piPayload{Tool: piToolPayload{Summary: "tool summary"}},
			want:    "tool summary",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := piToolActivity(tt.payload); got != tt.want {
				t.Fatalf("piToolActivity() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHookPiMessageActivityUsesStreamingText(t *testing.T) {
	tests := []struct {
		action  string
		payload map[string]interface{}
		want    string
	}{
		{
			action:  "message_update",
			payload: map[string]interface{}{"snippet": "Streaming answer\nignored"},
			want:    "Streaming answer",
		},
		{
			action: "message_end",
			payload: map[string]interface{}{
				"message": map[string]interface{}{
					"role":    "assistant",
					"content": []interface{}{map[string]interface{}{"type": "text", "text": "Finished answer\nignored"}},
				},
			},
			want: "Finished answer",
		},
	}

	for _, tt := range tests {
		t.Run(tt.action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, "pi", tt.action, "qm-abc", tt.payload)
			pane := rec.lastState.Panes["primary"]
			if pane.Activity != tt.want {
				t.Fatalf("activity: want %q, got %q", tt.want, pane.Activity)
			}
		})
	}
}

func TestHookPiMessageActivityFallsBackWhenTextMissing(t *testing.T) {
	for _, action := range []string{"message_update", "message_end"} {
		t.Run(action, func(t *testing.T) {
			r, rec := newTestRunner(t)
			runHookWithStdin(r, "pi", action, "qm-abc", nil)
			pane := rec.lastState.Panes["primary"]
			if pane.Activity != "Replying…" {
				t.Fatalf("activity: want %q, got %q", "Replying…", pane.Activity)
			}
		})
	}
}

func TestHookPiWaitingForUserBlocksWithQuestion(t *testing.T) {
	r, rec := newTestRunner(t)
	runHookWithStdin(r, "pi", "waiting_for_user", "qm-abc", map[string]interface{}{
		"prompt": "Pick a deployment target\nignored",
		"tool":   map[string]interface{}{"name": "ask_user", "summary": "Fallback question"},
	})
	pane := rec.lastState.Panes["primary"]
	if pane.State != "blocked" {
		t.Fatalf("state: want %q, got %+v", "blocked", pane)
	}
	if !strings.HasPrefix(pane.Activity, "Question: ") {
		t.Fatalf("activity should start with Question: got %q", pane.Activity)
	}
	if pane.Activity != "Question: Pick a deployment target" {
		t.Fatalf("activity: want %q, got %q", "Question: Pick a deployment target", pane.Activity)
	}
	if pane.Tool != "ask_user" {
		t.Fatalf("tool: want %q, got %q", "ask_user", pane.Tool)
	}
	if pane.LastKind != "waiting_for_user" {
		t.Fatalf("last_kind: want %q, got %q", "waiting_for_user", pane.LastKind)
	}

	runHookWithStdin(r, "pi", "tool_execution_start", "qm-abc", map[string]interface{}{"toolName": "ask_user"})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "blocked" || pane.Activity != "Question: Pick a deployment target" || pane.LastKind != "waiting_for_user" {
		t.Fatalf("tool heartbeat should preserve blocked question, got %+v", pane)
	}

	runHookWithStdin(r, "pi", "tool_execution_end", "qm-abc", map[string]interface{}{"toolName": "ask_user"})
	pane = rec.lastState.Panes["primary"]
	if pane.State != "working" || pane.Activity != "" || pane.Tool != "" || pane.LastKind != "tool_execution_end" {
		t.Fatalf("tool end should clear blocked question, got %+v", pane)
	}
}

func TestHookPiEventsEndToEnd(t *testing.T) {
	r, rec := newTestRunner(t)
	command := "OPENAI_API_KEY=sk-xxx echo hello from pi"
	steps := []struct {
		action       string
		payload      map[string]interface{}
		wantState    string
		wantActivity string
		wantTool     string
	}{
		{
			action: "session_start",
			payload: map[string]interface{}{
				"session_file":  "2026-05-20T12-00-00-000Z_123e4567-e89b-12d3-a456-426614174000.jsonl",
				"pi_session_id": "123e4567-e89b-12d3-a456-426614174000",
				"recent":        []string{"previous line"},
			},
			wantState:    "starting",
			wantActivity: "started",
		},
		{action: "before_agent_start", wantState: "starting", wantActivity: "started"},
		{action: "agent_start", wantState: "starting", wantActivity: "started"},
		{action: "message_update", wantState: "working", wantActivity: "Replying…"},
		{
			action: "message_end",
			payload: map[string]interface{}{
				"message": map[string]interface{}{
					"role":    "assistant",
					"content": []interface{}{map[string]interface{}{"type": "text", "text": "Hello\nfrom Pi"}},
				},
			},
			wantState:    "working",
			wantActivity: "Hello",
		},
		{
			action: "tool_execution_start",
			payload: map[string]interface{}{
				"toolName": "bash",
				"args":     map[string]interface{}{"command": command},
			},
			wantState:    "working",
			wantActivity: "Bash: echo hello from pi",
			wantTool:     "bash",
		},
		{action: "tool_execution_end", payload: map[string]interface{}{"toolName": "bash"}, wantState: "working", wantActivity: "Bash: echo hello from pi"},
		{
			action: "agent_end",
			payload: map[string]interface{}{
				"messages": []interface{}{
					map[string]interface{}{"role": "user", "content": "ignored"},
					map[string]interface{}{"role": "assistant", "content": []interface{}{map[string]interface{}{"type": "text", "text": "Final answer\nsecond line ignored"}}},
				},
			},
			wantState:    "done",
			wantActivity: "Final answer",
		},
		{action: "session_shutdown", wantState: "stopped", wantActivity: "Final answer"},
	}

	for _, step := range steps {
		stderr := runHookWithStdin(r, "pi", step.action, "qm-abc", step.payload)
		if stderr != "" {
			t.Fatalf("%s stderr: %q", step.action, stderr)
		}
		pane := rec.lastState.Panes["primary"]
		if pane.State != step.wantState {
			t.Fatalf("%s state: want %q, got %+v", step.action, step.wantState, pane)
		}
		if pane.Activity != step.wantActivity {
			t.Fatalf("%s activity: want %q, got %q", step.action, step.wantActivity, pane.Activity)
		}
		if pane.Tool != step.wantTool {
			t.Fatalf("%s tool: want %q, got %q", step.action, step.wantTool, pane.Tool)
		}
		if pane.Agent != "pi" || pane.Role != "primary" {
			t.Fatalf("%s pane identity: %+v", step.action, pane)
		}
		if pane.LastKind != step.action {
			t.Fatalf("%s last_kind: %q", step.action, pane.LastKind)
		}
	}

	pane := rec.lastState.Panes["primary"]
	if pane.SessionFile != "2026-05-20T12-00-00-000Z_123e4567-e89b-12d3-a456-426614174000.jsonl" {
		t.Errorf("session_file not carried through: %q", pane.SessionFile)
	}
	if pane.PiSessionID != "123e4567-e89b-12d3-a456-426614174000" {
		t.Errorf("pi_session_id not carried through: %q", pane.PiSessionID)
	}
	if len(pane.Recent) == 0 || pane.Recent[len(pane.Recent)-1] != "second line ignored" {
		t.Errorf("recent not carried through/derived: %+v", pane.Recent)
	}
	if len(rec.events) != len(steps) {
		t.Errorf("event count: want %d, got %d", len(steps), len(rec.events))
	}
	if rec.updateCalls != len(steps) || rec.writeCalls != len(steps) {
		t.Errorf("updates/writes: want %d/%d, got %d/%d", len(steps), len(steps), rec.updateCalls, rec.writeCalls)
	}
}

// TestHookDoesNotCallDiscoverSessions enforces that the hook hot path
// never enumerates sessions. We parse the source and walk the AST for
// any reference to "DiscoverSessions".
func TestHookDoesNotCallDiscoverSessions(t *testing.T) {
	src, err := os.ReadFile("hook.go")
	if err != nil {
		t.Fatalf("read hook.go: %v", err)
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "hook.go", src, 0)
	if err != nil {
		t.Fatalf("parse hook.go: %v", err)
	}
	ast.Inspect(f, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.SelectorExpr:
			if node.Sel != nil && node.Sel.Name == "DiscoverSessions" {
				t.Errorf("hook.go references DiscoverSessions at %s", fset.Position(node.Pos()))
			}
		case *ast.Ident:
			if node.Name == "DiscoverSessions" {
				t.Errorf("hook.go references DiscoverSessions at %s", fset.Position(node.Pos()))
			}
		}
		return true
	})
}

// TestRoundTripState writes via UpdateSessionState then loads via
// LoadSessionState. This double-checks the runHook path against the real
// disk-backed store (no fake HookRunner).
func TestHookEndToEndOnDisk(t *testing.T) {
	root := setTestStateRoot(t)

	r := defaultHookRunner()
	r.Now = func() time.Time { return time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC) }
	r.LoadTranscriptTail = func(string) ([]byte, error) { return nil, nil }

	for _, step := range []struct {
		action  string
		payload map[string]interface{}
	}{
		{"starting", nil},
		{"working", map[string]interface{}{"prompt": "hi there"}},
		{"tool_start", map[string]interface{}{"tool_name": "Edit", "tool_input": map[string]interface{}{"file_path": "/x/y.go"}}},
		{"tool_end", map[string]interface{}{"tool_name": "Edit"}},
		{"done", nil},
	} {
		var data []byte
		if step.payload != nil {
			data, _ = json.Marshal(step.payload)
		}
		var buf bytes.Buffer
		runHook(r, hookOptions{agent: "claude", action: step.action, session: "qm-disk", stdin: data}, &buf)
		if s := buf.String(); s != "" {
			t.Errorf("step %s stderr: %q", step.action, s)
		}
	}

	ss, err := state.LoadSessionState("qm-disk")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if ss.Panes["primary"].State != "done" {
		t.Errorf("final state: %+v", ss.Panes["primary"])
	}
	if _, err := os.Stat(filepath.Join(root, "qm-disk", "state.jsonl")); err != nil {
		t.Errorf("state.jsonl missing: %v", err)
	}
}

// TestHookClaudeWorkingSinceLifecycle exercises all three WorkingSince
// transitions in one test against the Claude hook path, which is
// structurally identical to the Codex and Pi setState branches:
//
//  1. idle → working: WorkingSince is stamped with `now`.
//  2. working → working (PreTool → PostTool roundtrip): WorkingSince is
//     PRESERVED. This is the critical case — every tool event during a
//     turn lands here, and the renderer's duration suffix relies on a
//     stable origin.
//  3. working → done: WorkingSince is cleared back to the zero value.
func TestHookClaudeWorkingSinceLifecycle(t *testing.T) {
	fixedNow := time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)

	t.Run("first transition stamps WorkingSince", func(t *testing.T) {
		r, rec := newTestRunner(t)
		runHookWithStdin(r, "claude", "working", "qm-abc", map[string]interface{}{"prompt": "go"})
		pane := rec.lastState.Panes["primary"]
		if pane.State != "working" {
			t.Fatalf("state = %q, want working", pane.State)
		}
		if !pane.WorkingSince.Equal(fixedNow) {
			t.Fatalf("WorkingSince = %v, want %v", pane.WorkingSince, fixedNow)
		}
	})

	t.Run("working→working preserves WorkingSince", func(t *testing.T) {
		r, rec := newTestRunner(t)
		// Seed an already-working pane with a prior WorkingSince well
		// before the runner's fixed Now. If the hook overwrote it,
		// pane.WorkingSince would jump to fixedNow.
		prior := fixedNow.Add(-90 * time.Second)
		rec.lastState = &state.SessionState{
			SessionID: "qm-abc",
			Version:   state.SchemaVersion,
			Panes: map[string]state.PaneState{
				"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", Tool: "Edit", LastKind: "PreToolUse", WorkingSince: prior},
			},
		}
		// PostToolUse (working → working) is the everyday case.
		runHookWithStdin(r, "claude", "tool_end", "qm-abc", map[string]interface{}{"tool_name": "Edit"})
		pane := rec.lastState.Panes["primary"]
		if pane.State != "working" {
			t.Fatalf("state = %q, want working", pane.State)
		}
		if !pane.WorkingSince.Equal(prior) {
			t.Fatalf("WorkingSince was clobbered: got %v, want %v (preserved across working→working)", pane.WorkingSince, prior)
		}
	})

	t.Run("working→working backfills missing WorkingSince from prior event", func(t *testing.T) {
		r, rec := newTestRunner(t)
		prior := fixedNow.Add(-5 * time.Minute)
		rec.lastState = &state.SessionState{
			SessionID: "qm-abc",
			Version:   state.SchemaVersion,
			Panes: map[string]state.PaneState{
				"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Edit: foo.go", Tool: "Edit", LastKind: "PreToolUse", LastEvent: prior},
			},
		}
		// Older state files can already be working with no working_since.
		runHookWithStdin(r, "claude", "tool_end", "qm-abc", map[string]interface{}{"tool_name": "Edit"})
		pane := rec.lastState.Panes["primary"]
		if pane.State != "working" {
			t.Fatalf("state = %q, want working", pane.State)
		}
		if !pane.WorkingSince.Equal(prior) {
			t.Fatalf("WorkingSince = %v, want prior last_event %v", pane.WorkingSince, prior)
		}
	})

	t.Run("state-preserving subagent hook backfills missing WorkingSince", func(t *testing.T) {
		r, rec := newTestRunner(t)
		prior := fixedNow.Add(-7 * time.Minute)
		rec.lastState = &state.SessionState{
			SessionID: "qm-abc",
			Version:   state.SchemaVersion,
			Panes: map[string]state.PaneState{
				"primary": {Role: "primary", Agent: "claude", State: "working", Activity: "Thinking", LastKind: "UserPromptSubmit", LastEvent: prior},
			},
		}
		runHookWithStdin(r, "claude", "tool_start", "qm-abc", map[string]interface{}{
			"agent_id":   "subagent-1",
			"tool_name":  "Read",
			"tool_input": map[string]interface{}{"file_path": "/tmp/foo.go"},
		})
		pane := rec.lastState.Panes["primary"]
		if pane.State != "working" {
			t.Fatalf("state = %q, want working", pane.State)
		}
		if !pane.WorkingSince.Equal(prior) {
			t.Fatalf("WorkingSince = %v, want prior last_event %v", pane.WorkingSince, prior)
		}
		if !pane.LastEvent.Equal(fixedNow) {
			t.Fatalf("LastEvent = %v, want current hook time %v", pane.LastEvent, fixedNow)
		}
	})

	t.Run("working→done clears WorkingSince", func(t *testing.T) {
		r, rec := newTestRunner(t)
		rec.transcriptTail = []byte("ok done")
		prior := fixedNow.Add(-30 * time.Second)
		rec.lastState = &state.SessionState{
			SessionID: "qm-abc",
			Version:   state.SchemaVersion,
			Panes: map[string]state.PaneState{
				"primary": {Role: "primary", Agent: "claude", State: "working", LastKind: "PreToolUse", WorkingSince: prior},
			},
		}
		runHookWithStdin(r, "claude", "done", "qm-abc", map[string]interface{}{
			"transcript_path": filepath.Join(t.TempDir(), "transcript.jsonl"),
		})
		pane := rec.lastState.Panes["primary"]
		if pane.State != "done" {
			t.Fatalf("state = %q, want done", pane.State)
		}
		if !pane.WorkingSince.IsZero() {
			t.Fatalf("WorkingSince = %v, want zero (cleared on leaving working)", pane.WorkingSince)
		}
	})
}

func TestHookWorkingSinceOnlyBackfillWritesState(t *testing.T) {
	fixedNow := time.Date(2026, 5, 20, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name     string
		agent    string
		action   string
		lastKind string
		payload  map[string]interface{}
	}{
		{name: "claude", agent: "claude", action: "tool_end", lastKind: "PostToolUse", payload: map[string]interface{}{"tool_name": "Edit"}},
		{name: "codex", agent: "codex", action: "tool_end", lastKind: "PostToolUse", payload: map[string]interface{}{"tool_name": "Edit"}},
		{name: "pi", agent: "pi", action: "tool_execution_end", lastKind: "tool_execution_end"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, rec := newTestRunner(t)
			rec.lastState = &state.SessionState{
				SessionID: "qm-abc",
				Version:   state.SchemaVersion,
				Panes: map[string]state.PaneState{
					"primary": {Role: "primary", Agent: tc.agent, State: "working", LastKind: tc.lastKind, LastEvent: fixedNow},
				},
			}

			runHookWithStdin(r, tc.agent, tc.action, "qm-abc", tc.payload)
			if rec.writeCalls != 1 {
				t.Fatalf("writeCalls = %d, want 1 for WorkingSince-only renderer-visible change", rec.writeCalls)
			}
			pane := rec.lastState.Panes["primary"]
			if !pane.WorkingSince.Equal(fixedNow) {
				t.Fatalf("WorkingSince = %v, want %v", pane.WorkingSince, fixedNow)
			}
		})
	}
}
