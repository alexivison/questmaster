//go:build linux || darwin

package state

import (
	"encoding/json"
	"fmt"
	"slices"
	"testing"
)

func TestManifest_MarshalJSON_NoExtraPreservesStructFieldOrder(t *testing.T) {
	t.Parallel()

	m := Manifest{
		SessionID:     "qm-x",
		SessionType: "master",
		Workers:     []string{"qm-w1", "qm-w2"},
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	want := `{"session_id":"qm-x","session_type":"master","workers":["qm-w1","qm-w2"]}`
	if string(data) != want {
		t.Fatalf("marshal mismatch:\n got: %s\nwant: %s", data, want)
	}
}

func TestManifest_MarshalJSON_WithExtraPreservesMergedOrder(t *testing.T) {
	t.Parallel()

	m := Manifest{
		SessionID: "qm-f",
		Cwd:     "/tmp/work",
		Extra: map[string]json.RawMessage{
			"feature_flag":   json.RawMessage(`true`),
			"initial_prompt": json.RawMessage(`"hello"`),
			"nested":         json.RawMessage(`{"level":[1,2,3]}`),
			"priority":       json.RawMessage(`7`),
		},
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	want := `{"cwd":"/tmp/work","feature_flag":true,"initial_prompt":"hello","nested":{"level":[1,2,3]},"priority":7,"session_id":"qm-f"}`
	if string(data) != want {
		t.Fatalf("marshal mismatch:\n got: %s\nwant: %s", data, want)
	}
}

func TestManifest_MarshalJSON_ExtraCanFillOmittedKnownField(t *testing.T) {
	t.Parallel()

	m := Manifest{
		SessionID: "qm-extra-title",
		Extra: map[string]json.RawMessage{
			"title": json.RawMessage(`"from-extra"`),
		},
	}

	data, err := json.Marshal(m)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	want := `{"session_id":"qm-extra-title","title":"from-extra"}`
	if string(data) != want {
		t.Fatalf("marshal mismatch:\n got: %s\nwant: %s", data, want)
	}
}

func TestManifest_UnmarshalJSON_KnownAndUnknownFieldsRoundTrip(t *testing.T) {
	t.Parallel()

	input := `{"session_id":"qm-rt","cwd":"/tmp/rt","enabled":true,"count":7,"label":"wizard","metadata":{"nested":{"ok":true},"workers":[1,2]},"agents":[{"name":"claude","role":"primary","cli":"/usr/local/bin/claude","resume_id":"resume-1","window":1}]}`

	var got Manifest
	if err := json.Unmarshal([]byte(input), &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if got.SessionID != "qm-rt" {
		t.Fatalf("SessionID: got %q, want %q", got.SessionID, "qm-rt")
	}
	if got.Cwd != "/tmp/rt" {
		t.Fatalf("Cwd: got %q, want %q", got.Cwd, "/tmp/rt")
	}
	if len(got.Extra) != 4 {
		t.Fatalf("extra count: got %d, want 4", len(got.Extra))
	}
	if got.ExtraString("label") != "wizard" {
		t.Fatalf("label: got %q, want %q", got.ExtraString("label"), "wizard")
	}

	data, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	assertJSONEqual(t, []byte(input), data)
}

func TestManifest_UnmarshalJSON_EmptyExtraRemainsEmpty(t *testing.T) {
	t.Parallel()

	input := `{"session_id":"qm-empty","cwd":"/tmp/empty","workers":["qm-w1"]}`

	var got Manifest
	if err := json.Unmarshal([]byte(input), &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if len(got.Extra) != 0 {
		t.Fatalf("Extra: got %d keys, want 0", len(got.Extra))
	}

	data, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	want := `{"session_id":"qm-empty","cwd":"/tmp/empty","workers":["qm-w1"]}`
	if string(data) != want {
		t.Fatalf("marshal mismatch:\n got: %s\nwant: %s", data, want)
	}
}

func TestManifest_DisplayMetadataRoundTrip(t *testing.T) {
	t.Parallel()

	input := `{"session_id":"qm-display","display":{"badge":"leader","color":"magenta","weight":2}}`

	var got Manifest
	if err := json.Unmarshal([]byte(input), &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if got.Display == nil {
		t.Fatal("Display = nil, want metadata")
	}
	if got.Display.Color != "magenta" {
		t.Fatalf("display.color = %q, want magenta", got.Display.Color)
	}
	if len(got.Display.Extra) != 2 {
		t.Fatalf("display extra count = %d, want 2", len(got.Display.Extra))
	}

	data, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	assertJSONEqual(t, []byte(input), data)
}

func TestManifest_UnmarshalJSON_LargeExtraRoundTrip(t *testing.T) {
	t.Parallel()

	input := map[string]any{
		"session_id": "qm-large",
		"cwd":      "/tmp/large",
	}
	for i := 0; i < 128; i++ {
		switch i % 4 {
		case 0:
			input[fmt.Sprintf("extra_%03d", i)] = i
		case 1:
			input[fmt.Sprintf("extra_%03d", i)] = i%2 == 0
		case 2:
			input[fmt.Sprintf("extra_%03d", i)] = fmt.Sprintf("value-%03d", i)
		default:
			input[fmt.Sprintf("extra_%03d", i)] = map[string]any{
				"index": i,
				"tags":  []string{"alpha", "beta"},
			}
		}
	}

	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatalf("Marshal input: %v", err)
	}

	var got Manifest
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if len(got.Extra) != 128 {
		t.Fatalf("Extra: got %d keys, want 128", len(got.Extra))
	}

	data, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}

	assertJSONEqual(t, raw, data)
}

func TestManifest_UnmarshalJSON_SanitizesResumeIDsOnce(t *testing.T) {
	t.Parallel()

	input := `{"session_id":"qm-sanitize","agents":[{"name":"claude","role":"primary","cli":"/usr/local/bin/claude","resume_id":"bad/path","window":1}],"claude_session_id":"sess-*","codex_thread_id":"valid-thread-1","pi_session_id":"../pi"}`

	var got Manifest
	if err := json.Unmarshal([]byte(input), &got); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}

	if got.Agents[0].ResumeID != "" {
		t.Fatalf("resume_id: got %q, want empty", got.Agents[0].ResumeID)
	}
	if got.ExtraString("claude_session_id") != "" {
		t.Fatalf("claude_session_id: got %q, want empty", got.ExtraString("claude_session_id"))
	}
	if got.ExtraString("codex_thread_id") != "valid-thread-1" {
		t.Fatalf("codex_thread_id: got %q, want %q", got.ExtraString("codex_thread_id"), "valid-thread-1")
	}
	if got.ExtraString("pi_session_id") != "" {
		t.Fatalf("pi_session_id: got %q, want empty", got.ExtraString("pi_session_id"))
	}
}

func assertJSONEqual(t *testing.T, want, got []byte) {
	t.Helper()

	var wantObj any
	if err := json.Unmarshal(want, &wantObj); err != nil {
		t.Fatalf("unmarshal want: %v", err)
	}

	var gotObj any
	if err := json.Unmarshal(got, &gotObj); err != nil {
		t.Fatalf("unmarshal got: %v", err)
	}

	if !jsonDeepEqual(wantObj, gotObj) {
		t.Fatalf("json mismatch:\n got: %s\nwant: %s", got, want)
	}
}

func jsonDeepEqual(a, b any) bool {
	switch va := a.(type) {
	case map[string]any:
		vb, ok := b.(map[string]any)
		if !ok || len(va) != len(vb) {
			return false
		}
		for key, value := range va {
			if !jsonDeepEqual(value, vb[key]) {
				return false
			}
		}
		return true
	case []any:
		vb, ok := b.([]any)
		if !ok || len(va) != len(vb) {
			return false
		}
		for i := range va {
			if !jsonDeepEqual(va[i], vb[i]) {
				return false
			}
		}
		return true
	case []string:
		vb, ok := b.([]string)
		return ok && slices.Equal(va, vb)
	default:
		return fmt.Sprint(a) == fmt.Sprint(b)
	}
}
