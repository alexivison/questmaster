package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

const (
	claudeNarrationEarlierAt = "2026-10-29T07:09:40.000Z"
	claudeNarrationFirstAt   = "2026-10-29T07:09:45.195Z"
	claudeNarrationSecondAt  = "2026-10-29T07:09:50.500Z"
)

// claudeTranscriptRecord is one transcript line the way Claude Code writes one
// content block: an assistant record that holds that block alone.
func claudeTranscriptRecord(t *testing.T, timestamp string, block map[string]interface{}) string {
	t.Helper()
	line, err := json.Marshal(map[string]interface{}{
		"type":      "assistant",
		"timestamp": timestamp,
		"message":   map[string]interface{}{"role": "assistant", "content": []interface{}{block}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(line)
}

func claudeThinkingBlock(text string) map[string]interface{} {
	return map[string]interface{}{"type": "thinking", "thinking": text, "signature": "c2lnbmF0dXJl"}
}

func claudeToolUseBlock(name string) map[string]interface{} {
	return map[string]interface{}{"type": "tool_use", "id": "toolu_" + name, "name": name, "input": map[string]interface{}{}}
}

func appendClaudeTranscript(t *testing.T, path, line string) {
	t.Helper()
	appendClaudeTranscriptRaw(t, path, line+"\n")
}

func appendClaudeTranscriptRaw(t *testing.T, path, text string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

func claudeNarrationTexts(narrations []claudeNarration) []string {
	texts := make([]string, 0, len(narrations))
	for _, n := range narrations {
		texts = append(texts, n.text)
	}
	return texts
}

// claudeSayTexts returns every say entry recorded so far, across all events, in order.
func claudeSayTexts(rec *recordedHookCalls) []string {
	var texts []string
	for _, event := range rec.events {
		for _, entry := range chatEntries(event) {
			if entry["chat_kind"] != "say" {
				continue
			}
			text, _ := entry["chat_text"].(string)
			texts = append(texts, text)
		}
	}
	return texts
}

func claudeChatKinds(event state.StateEvent) []string {
	var kinds []string
	for _, entry := range chatEntries(event) {
		kind, _ := entry["chat_kind"].(string)
		kinds = append(kinds, kind)
	}
	return kinds
}

func TestReadClaudeNarrationReturnsOnlyVisibleThinking(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name string
		line string
		want []string
	}{
		{
			name: "visible thinking is narration",
			line: claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("Reading the README.")),
			want: []string{"Reading the README."},
		},
		{
			name: "redacted thinking stays hidden",
			line: claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("")),
			want: nil,
		},
		{
			name: "whitespace-only thinking stays hidden",
			line: claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock(" \n ")),
			want: nil,
		},
		{
			name: "text blocks are left to MessageDisplay",
			line: claudeTranscriptRecord(t, claudeNarrationFirstAt, map[string]interface{}{"type": "text", "text": "Done."}),
			want: nil,
		},
		{
			name: "api request blobs repeat the blocks and are ignored",
			line: `{"type":"api-request-blob","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Reading the README.","signature":"c2ln"}]}}`,
			want: nil,
		},
		{
			name: "user records that quote thinking are ignored",
			line: `{"type":"user","timestamp":"` + claudeNarrationFirstAt + `","message":{"role":"user","content":[{"type":"tool_result","content":"\"thinking\": \"quoted\""}]}}`,
			want: nil,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(t.TempDir(), "transcript.jsonl")
			appendClaudeTranscript(t, path, tc.line)
			got, _, _, err := readClaudeNarration(path, 0, false)
			if err != nil {
				t.Fatalf("read transcript: %v", err)
			}
			if texts := claudeNarrationTexts(got); !slices.Equal(texts, tc.want) {
				t.Fatalf("narration = %#v, want %#v", texts, tc.want)
			}
		})
	}
}

func TestReadClaudeNarrationKeepsRecordTimestamp(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("Reading the README.")))
	got, _, _, err := readClaudeNarration(path, 0, false)
	if err != nil || len(got) != 1 {
		t.Fatalf("narration = %#v, err %v", got, err)
	}
	want, _ := time.Parse(time.RFC3339Nano, claudeNarrationFirstAt)
	if !got[0].timestamp.Equal(want) {
		t.Fatalf("timestamp = %s, want record timestamp %s", got[0].timestamp, want)
	}
}

func TestReadClaudeNarrationConsumesCompleteLinesOnly(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	first := claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("First."))
	second := claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeThinkingBlock("Second."))
	appendClaudeTranscript(t, path, first)
	half := len(second) / 2
	appendClaudeTranscriptRaw(t, path, second[:half])

	got, offset, skipping, err := readClaudeNarration(path, 0, false)
	if err != nil || !slices.Equal(claudeNarrationTexts(got), []string{"First."}) {
		t.Fatalf("first read = %#v, err %v", claudeNarrationTexts(got), err)
	}
	if offset != int64(len(first)+1) || skipping {
		t.Fatalf("first read offset = %d skipping = %t, want offset %d before the partial line", offset, skipping, len(first)+1)
	}

	appendClaudeTranscriptRaw(t, path, second[half:]+"\n")
	got, next, _, err := readClaudeNarration(path, offset, false)
	if err != nil || !slices.Equal(claudeNarrationTexts(got), []string{"Second."}) {
		t.Fatalf("completed read = %#v, err %v", claudeNarrationTexts(got), err)
	}
	if next <= offset {
		t.Fatalf("completed read offset = %d, want past %d", next, offset)
	}
}

func TestReadClaudeNarrationSkipsOversizedLine(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "transcript.jsonl")
	oversized := strings.Repeat("x", claudeTranscriptReadLimit+100)
	narration := claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("After the large result."))
	contents := oversized + "\n" + narration + "\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}

	got, offset, skipping, err := readClaudeNarration(path, 0, false)
	if err != nil || len(got) != 0 || !skipping || offset != claudeTranscriptReadLimit {
		t.Fatalf("oversized read = %#v offset=%d skipping=%t err=%v", claudeNarrationTexts(got), offset, skipping, err)
	}
	got, offset, skipping, err = readClaudeNarration(path, offset, skipping)
	if err != nil || !slices.Equal(claudeNarrationTexts(got), []string{"After the large result."}) || skipping || offset != int64(len(contents)) {
		t.Fatalf("continuation = %#v offset=%d skipping=%t err=%v", claudeNarrationTexts(got), offset, skipping, err)
	}
}

func TestReadClaudeNarrationMissingOrTruncatedTranscript(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	got, offset, skipping, err := readClaudeNarration(filepath.Join(dir, "missing.jsonl"), 7, false)
	if err != nil || len(got) != 0 || offset != 7 || skipping {
		t.Fatalf("missing transcript = %#v offset=%d skipping=%t err=%v, want no read and offset kept", got, offset, skipping, err)
	}

	path := filepath.Join(dir, "transcript.jsonl")
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("Old.")))
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	got, offset, _, err = readClaudeNarration(path, info.Size(), false)
	if err != nil || len(got) != 0 || offset != 0 {
		t.Fatalf("truncated transcript = %#v offset=%d err=%v, want end-of-file offset 0", got, offset, err)
	}
}

func newClaudeNarrationRunner(t *testing.T) (*HookRunner, *recordedHookCalls, string) {
	t.Helper()
	r, rec := newTestRunner(t)
	return r, rec, filepath.Join(t.TempDir(), "transcript.jsonl")
}

func runClaudeHook(r *HookRunner, action string, payload map[string]interface{}) {
	runHookWithStdin(r, "claude", action, "qm-claude", payload)
}

func TestHookClaudeNarrationBeforeToolStartBecomesSay(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationEarlierAt, claudeThinkingBlock("Previous turn narration.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationEarlierAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("I'll run the tests.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Bash")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Bash"})

	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"I'll run the tests."}) {
		t.Fatalf("say texts = %#v, want only the narration written after the prompt", got)
	}
	event := latestHookEvent(t, rec)
	if kinds := claudeChatKinds(event); !slices.Equal(kinds, []string{"say", "action"}) {
		t.Fatalf("chat kinds = %#v, want the narration say before the action", kinds)
	}
	want, _ := time.Parse(time.RFC3339Nano, claudeNarrationFirstAt)
	if got, ok := chatEntries(event)[0]["chat_timestamp"].(time.Time); !ok || !got.Equal(want) {
		t.Fatalf("say timestamp = %#v, want record timestamp %s", chatEntries(event)[0]["chat_timestamp"], want)
	}
	if got := rec.lastState.Panes["agent"].Narration; got != "I'll run the tests." {
		t.Fatalf("pane narration = %q, want the say text", got)
	}
}

func TestHookClaudeRedactedThinkingIsNotSaid(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})

	if got := claudeSayTexts(rec); len(got) != 0 {
		t.Fatalf("say texts = %#v, want none for redacted thinking", got)
	}
	if got := rec.lastState.Panes["agent"].Narration; got != "" {
		t.Fatalf("pane narration = %q, want empty", got)
	}
}

func TestHookClaudeNarrationAndTextBlockEachSaidOnce(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("I'll check the build.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Bash")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Bash"})

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, map[string]interface{}{"type": "text", "text": "Done."}))
	runClaudeHook(r, "say", map[string]interface{}{"message_id": "m1", "prompt_id": "p1", "index": 0, "final": true, "delta": "Done."})
	runClaudeHook(r, "done", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "last_assistant_message": "Done."})

	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"I'll check the build.", "Done."}) {
		t.Fatalf("say texts = %#v, want each block once", got)
	}
	for _, event := range rec.events {
		if kinds := claudeChatKinds(event); slices.Contains(kinds, "message") {
			t.Fatalf("message entry %v added after the text block was already said", kinds)
		}
	}
}

func TestHookClaudeNarrationIsSaidOnceAcrossHooks(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("Reading the config.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t2", "tool_name": "Read"})

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeThinkingBlock("Editing the config.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeToolUseBlock("Edit")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t3", "tool_name": "Edit"})
	runClaudeHook(r, "done", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})

	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"Reading the config.", "Editing the config."}) {
		t.Fatalf("say texts = %#v, want each narration once and in order", got)
	}
}

func TestHookClaudeNarrationAfterLastToolIsSaidBeforeFinalMessage(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Bash")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Bash"})

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeThinkingBlock("Checking the final state.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, map[string]interface{}{"type": "text", "text": "All green."}))
	runClaudeHook(r, "done", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "last_assistant_message": "All green."})

	event := latestHookEvent(t, rec)
	entries := chatEntries(event)
	if kinds := claudeChatKinds(event); !slices.Equal(kinds, []string{"say", "message", "status"}) {
		t.Fatalf("done chat kinds = %#v, want narration before the final message and the done status after it", kinds)
	}
	if entries[0]["chat_text"] != "Checking the final state." || entries[1]["chat_text"] != "All green." {
		t.Fatalf("done chat = %#v", entries)
	}
}

func TestHookClaudeNewPromptStartsAtItsOwnNarration(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("First turn.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})
	runClaudeHook(r, "done", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})

	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p2", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p2", "transcript_path": path, "tool_use_id": "t2", "tool_name": "Read"})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeThinkingBlock("Second turn.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeToolUseBlock("Edit")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p2", "transcript_path": path, "tool_use_id": "t3", "tool_name": "Edit"})

	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"First turn.", "Second turn."}) {
		t.Fatalf("say texts = %#v, want each turn's narration once", got)
	}
}

func TestHookClaudeNarrationFromNewTranscriptFileIsRead(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("First write of a new session.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})

	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"First write of a new session."}) {
		t.Fatalf("say texts = %#v, want narration from a transcript created after the prompt", got)
	}
}

func TestHookClaudeSubagentToolStartDoesNotReadParentNarration(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeThinkingBlock("Parent narration.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, claudeNarrationFirstAt, claudeToolUseBlock("Read")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "agent_id": "sub-1", "transcript_path": path, "tool_use_id": "s1", "tool_name": "Read"})
	if got := claudeSayTexts(rec); len(got) != 0 {
		t.Fatalf("subagent tool_start said %#v, want none", got)
	}

	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})
	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"Parent narration."}) {
		t.Fatalf("say texts = %#v, want the parent narration once", got)
	}
}

func TestHookClaudeTranscriptPathChangeStartsAtNewEnd(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	other := filepath.Join(t.TempDir(), "other.jsonl")
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, other, claudeTranscriptRecord(t, claudeNarrationEarlierAt, claudeThinkingBlock("Replayed history.")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": other, "tool_use_id": "t1", "tool_name": "Read"})
	if got := claudeSayTexts(rec); len(got) != 0 {
		t.Fatalf("say texts = %#v after switching transcripts, want no replay", got)
	}

	appendClaudeTranscript(t, other, claudeTranscriptRecord(t, claudeNarrationSecondAt, claudeThinkingBlock("New in the other file.")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": other, "tool_use_id": "t2", "tool_name": "Read"})
	if got := claudeSayTexts(rec); !slices.Equal(got, []string{"New in the other file."}) {
		t.Fatalf("say texts = %#v, want only narration written after the switch", got)
	}
}

func TestHookClaudeNarrationCursorIsWrittenWhenOnlyItMoves(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	line := claudeTranscriptRecord(t, claudeNarrationEarlierAt, claudeToolUseBlock("Read"))
	appendClaudeTranscript(t, path, line)
	rec.lastState = &state.SessionState{SessionID: "qm-claude", Version: state.SchemaVersion, Panes: map[string]state.PaneState{
		"agent": {
			Role: "agent", Agent: "claude", State: "working", LastKind: "UserPromptSubmit", WorkingSince: r.Now(),
			ClaudePromptID: "p1", ClaudeNarrationPath: path,
		},
	}}
	writes := rec.writeCalls

	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})

	if rec.writeCalls != writes+1 {
		t.Fatalf("writes = %d, want the cursor move written once", rec.writeCalls-writes)
	}
	if got, want := rec.lastState.Panes["agent"].ClaudeNarrationOffset, int64(len(line)+1); got != want {
		t.Fatalf("cursor = %d, want the end of the transcript %d", got, want)
	}
}

// claudeNarrationClockAt sets the hook clock, so say times and transcript
// timestamps sit on one timeline.
func claudeNarrationClockAt(t *testing.T, r *HookRunner, at string) {
	t.Helper()
	when, err := time.Parse(time.RFC3339Nano, at)
	if err != nil {
		t.Fatal(err)
	}
	r.Now = func() time.Time { return when }
}

func claudeTextBlock(text string) map[string]interface{} {
	return map[string]interface{}{"type": "text", "text": text}
}

// runClaudeMessageDisplay sends one text block the way MessageDisplay does: a
// single final batch.
func runClaudeMessageDisplay(r *HookRunner, promptID, messageID, text string) {
	runClaudeHook(r, "say", map[string]interface{}{
		"message_id": messageID, "prompt_id": promptID, "index": 0, "final": true, "delta": text,
	})
}

func countOf(texts []string, want string) int {
	n := 0
	for _, text := range texts {
		if text == want {
			n++
		}
	}
	return n
}

func TestHookClaudeLateNarrationKeepsNewerSayOnPlate(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:40Z")
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:44Z")
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:44Z", claudeToolUseBlock("Bash")))
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Bash"})

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:45.195Z", claudeThinkingBlock("Checking the final state.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:46Z", claudeTextBlock("All green.")))
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:46.100Z")
	runClaudeMessageDisplay(r, "p1", "m1", "All green.")
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:50Z")
	runClaudeHook(r, "done", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "last_assistant_message": "All green."})

	if got := rec.lastState.Panes["agent"].Narration; got != "All green." {
		t.Fatalf("plate line = %q, want the newer say", got)
	}
	if got := claudeSayTexts(rec); countOf(got, "Checking the final state.") != 1 || countOf(got, "All green.") != 1 {
		t.Fatalf("say texts = %#v, want each once", got)
	}
	if kinds := claudeChatKinds(latestHookEvent(t, rec)); slices.Contains(kinds, "message") {
		t.Fatalf("done chat kinds = %#v, want no message for the text already said", kinds)
	}
}

func TestHookClaudeNarrationBeforeSayKeepsSayOnPlate(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:40Z")
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:45.195Z", claudeThinkingBlock("Reading the config next.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:46Z", claudeTextBlock("Config looks right.")))
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:46.100Z")
	runClaudeMessageDisplay(r, "p1", "m1", "Config looks right.")

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:46.200Z", claudeToolUseBlock("Read")))
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:46.300Z")
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Read"})

	if got := rec.lastState.Panes["agent"].Narration; got != "Config looks right." {
		t.Fatalf("plate line = %q, want the text block's say", got)
	}
	if got := claudeSayTexts(rec); countOf(got, "Reading the config next.") != 1 {
		t.Fatalf("say texts = %#v, want the narration once", got)
	}
}

func TestHookClaudeNarrationAfterSayReplacesPlate(t *testing.T) {
	r, rec, path := newClaudeNarrationRunner(t)
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:40Z")
	runClaudeHook(r, "working", map[string]interface{}{"prompt_id": "p1", "transcript_path": path})
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:45Z", claudeTextBlock("Looking at the test.")))
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:45.100Z")
	runClaudeMessageDisplay(r, "p1", "m1", "Looking at the test.")

	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:48Z", claudeThinkingBlock("Now editing the test.")))
	appendClaudeTranscript(t, path, claudeTranscriptRecord(t, "2026-10-29T07:09:48.100Z", claudeToolUseBlock("Edit")))
	claudeNarrationClockAt(t, r, "2026-10-29T07:09:48.500Z")
	runClaudeHook(r, "tool_start", map[string]interface{}{"prompt_id": "p1", "transcript_path": path, "tool_use_id": "t1", "tool_name": "Edit"})

	if got := rec.lastState.Panes["agent"].Narration; got != "Now editing the test." {
		t.Fatalf("plate line = %q, want the newer narration", got)
	}
}
