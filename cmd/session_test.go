//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSessionNew_JSONAndPromptFile(t *testing.T) {
	store := setupStore(t)
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	out := runCmdInput(t, store, allPassRunner(), strings.NewReader("session prompt from stdin"), "session", "new", "--cwd", cwd, "--prompt-file", "-", "json-session")

	var got struct {
		SessionID  string `json:"session_id"`
		RuntimeDir string `json:"runtime_dir"`
		Cwd        string `json:"cwd"`
		Title      string `json:"title"`
		Master     bool   `json:"master"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("session new output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.RuntimeDir == "" || got.Cwd != cwd || got.Title != "json-session" || got.Master {
		t.Fatalf("session new JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if prompt := m.ExtraString("initial_prompt"); prompt != "session prompt from stdin" {
		t.Fatalf("initial_prompt = %q, want stdin prompt", prompt)
	}
}
