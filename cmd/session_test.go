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

	out := runCmdInput(t, store, allPassRunner(), strings.NewReader("session prompt from stdin"), "session", "new", "--cwd", cwd, "--class", "paladin", "--prompt-file", "-", "json-session")

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
	if got.SessionID == "" || got.RuntimeDir == "" || got.Cwd != cwd || got.Title != "json-session" || !got.Master {
		t.Fatalf("session new JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if prompt := m.ExtraString("initial_prompt"); prompt != "session prompt from stdin" {
		t.Fatalf("initial_prompt = %q, want stdin prompt", prompt)
	}
	if got := m.DisplayClass(); got != "paladin" {
		t.Fatalf("session class = %q, want paladin", got)
	}
}

func TestSessionNew_ShellFlagCreatesAgentlessSession(t *testing.T) {
	t.Parallel()

	store := setupStore(t)
	cwd := t.TempDir()

	out := runCmd(t, store, allPassRunner(), "session", "new", "--cwd", cwd, "--shell", "plain-session")
	var got struct {
		SessionID string `json:"session_id"`
		Cwd       string `json:"cwd"`
		Title     string `json:"title"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("session new shell output is not JSON: %v\n%s", err, out)
	}
	if got.SessionID == "" || got.Cwd != cwd || got.Title != "plain-session" {
		t.Fatalf("session new shell JSON mismatch: %#v", got)
	}
	m, err := store.Read(got.SessionID)
	if err != nil {
		t.Fatalf("read created manifest: %v", err)
	}
	if len(m.Agents) != 0 {
		t.Fatalf("shell manifest agents = %+v, want none", m.Agents)
	}
}

func TestSessionNewRejectsInvalidClass(t *testing.T) {
	store := setupStore(t)
	writeAgentConfig(t, "")
	_, err := runCmdErr(t, store, allPassRunner(), "session", "new", "--class", "ranger")
	if err == nil || !strings.Contains(err.Error(), "paladin, wizard, druid, barbarian, rogue, cleric, bard") {
		t.Fatalf("invalid session class error = %v, want supported class list", err)
	}
}
