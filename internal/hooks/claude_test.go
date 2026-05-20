package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func newTestClaudeInstaller(t *testing.T) *ClaudeInstaller {
	t.Helper()
	return &ClaudeInstaller{Home: t.TempDir()}
}

func readSettings(t *testing.T, c *ClaudeInstaller) map[string]interface{} {
	t.Helper()
	data, err := os.ReadFile(c.settingsPath())
	if err != nil {
		t.Fatalf("read settings: %v", err)
	}
	var out map[string]interface{}
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("parse settings: %v", err)
	}
	return out
}

func TestClaudeInstallCreatesScriptAndSettings(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	body, err := os.ReadFile(c.scriptPath())
	if err != nil {
		t.Fatalf("read script: %v", err)
	}
	if string(body) != RenderScript("claude") {
		t.Errorf("script body mismatch:\n%s", body)
	}
	info, err := os.Stat(c.scriptPath())
	if err != nil {
		t.Fatalf("stat script: %v", err)
	}
	if info.Mode()&0o111 == 0 {
		t.Error("script not executable")
	}
	got := readSettings(t, c)
	hooks, ok := got["hooks"].(map[string]interface{})
	if !ok {
		t.Fatalf("settings missing hooks: %+v", got)
	}
	for _, ev := range claudeEvents {
		raw, ok := hooks[ev.Event].([]interface{})
		if !ok || len(raw) == 0 {
			t.Errorf("missing entry for %s", ev.Event)
			continue
		}
		first, ok := raw[0].(map[string]interface{})
		if !ok {
			t.Errorf("entry for %s wrong shape: %T", ev.Event, raw[0])
			continue
		}
		if first["_party_cli"] != AssetTag {
			t.Errorf("entry for %s missing party tag: %+v", ev.Event, first)
		}
	}
}

func TestClaudeInstallIsIdempotent(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(c.settingsPath())
	if err != nil {
		t.Fatalf("read after first install: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(c.settingsPath())
	if err != nil {
		t.Fatalf("read after second install: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("re-install changed settings.local.json:\n--- first\n%s\n--- second\n%s\n", first, second)
	}
}

func TestClaudeInstallPreservesUserHooks(t *testing.T) {
	c := newTestClaudeInstaller(t)
	userSettings := map[string]interface{}{
		"effortLevel": "high",
		"hooks": map[string]interface{}{
			"PreToolUse": []interface{}{
				map[string]interface{}{
					"matcher": "Bash",
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "user-bash.sh"},
					},
				},
			},
			"SessionStart": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "user-start.sh"},
					},
				},
			},
		},
	}
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	data, _ := json.Marshal(userSettings)
	if err := os.WriteFile(c.settingsPath(), data, 0o644); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	got := readSettings(t, c)
	if got["effortLevel"] != "high" {
		t.Error("install clobbered unrelated settings")
	}
	hooks := got["hooks"].(map[string]interface{})
	pre := hooks["PreToolUse"].([]interface{})
	// User's untagged PreToolUse entry + one party_cli entry = 2.
	if len(pre) != 2 {
		t.Errorf("PreToolUse: want 2 entries (user + party_cli), got %d: %+v", len(pre), pre)
	}
	// Find the user entry — must be unchanged.
	var sawUser bool
	for _, raw := range pre {
		obj := raw.(map[string]interface{})
		if obj["matcher"] == "Bash" {
			sawUser = true
		}
	}
	if !sawUser {
		t.Error("user's PreToolUse:Bash entry was removed")
	}
}

func TestClaudeUninstallRemovesOnlyTaggedEntries(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	// Drop a user-managed entry alongside ours.
	settings := readSettings(t, c)
	hooks := settings["hooks"].(map[string]interface{})
	pre := hooks["PreToolUse"].([]interface{})
	pre = append(pre, map[string]interface{}{
		"matcher": "Edit",
		"hooks": []interface{}{
			map[string]interface{}{"type": "command", "command": "user-edit.sh"},
		},
	})
	hooks["PreToolUse"] = pre
	data, _ := json.Marshal(settings)
	if err := os.WriteFile(c.settingsPath(), data, 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(c.scriptPath()); err == nil {
		t.Error("script not removed")
	}
	got := readSettings(t, c)
	hooks2, _ := got["hooks"].(map[string]interface{})
	pre2, _ := hooks2["PreToolUse"].([]interface{})
	if len(pre2) != 1 {
		t.Errorf("want 1 surviving user entry, got %d: %+v", len(pre2), pre2)
	} else {
		obj := pre2[0].(map[string]interface{})
		if obj["_party_cli"] == AssetTag {
			t.Error("party-cli entry survived uninstall")
		}
		if obj["matcher"] != "Edit" {
			t.Errorf("wrong surviving entry: %+v", obj)
		}
	}
}

func TestClaudeBackupOncePerSettings(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	original := []byte(`{"effortLevel":"high"}`)
	if err := os.WriteFile(c.settingsPath(), original, 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install 1: %v", err)
	}
	backup1, err := os.ReadFile(c.backupPath())
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if string(backup1) != string(original) {
		t.Errorf("backup does not match original:\n%s\n--\n%s", backup1, original)
	}
	// Second install must not overwrite the backup.
	if err := c.Install(); err != nil {
		t.Fatalf("install 2: %v", err)
	}
	backup2, _ := os.ReadFile(c.backupPath())
	if string(backup1) != string(backup2) {
		t.Error("install overwrote existing backup — should be first-write-wins")
	}
}

func TestClaudeStatus(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if got := c.Status(); got.Status != StatusNotInstalled {
		t.Errorf("pre-install status: %+v", got)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if got := c.Status(); got.Status != StatusCurrent {
		t.Errorf("post-install status: %+v", got)
	}
	// Mutate the script — should flip to Outdated.
	if err := os.WriteFile(c.scriptPath(), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("clobber script: %v", err)
	}
	if got := c.Status(); got.Status == StatusCurrent {
		t.Errorf("modified script should not be Current: %+v", got)
	}
}

func TestRenderScriptSubstitutesAgent(t *testing.T) {
	for _, agent := range []string{"claude", "codex", "pi"} {
		body := RenderScript(agent)
		want := "exec party-cli hook " + agent + ` "$1"`
		if !contains(body, want) {
			t.Errorf("rendered %s script missing %q:\n%s", agent, want, body)
		}
		if contains(body, "__AGENT__") {
			t.Errorf("rendered %s script still contains placeholder", agent)
		}
	}
}

func contains(s, sub string) bool {
	return len(sub) == 0 || (len(s) >= len(sub) && (indexOf(s, sub) >= 0))
}

func indexOf(s, sub string) int {
	n := len(s) - len(sub)
	for i := 0; i <= n; i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

// TestSettingsRoundTripPreservesTag asserts that our `_party_cli` tag
// survives a JSON parse + re-marshal cycle (the round-trip Claude
// performs when reading and writing settings.local.json). PLAN.md
// "Settings.json round-trip safety" specifies this as a Phase 1 gate.
func TestSettingsRoundTripPreservesTag(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	data, err := os.ReadFile(c.settingsPath())
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("parse: %v", err)
	}
	reencoded, err := json.MarshalIndent(parsed, "", "  ")
	if err != nil {
		t.Fatalf("reencode: %v", err)
	}
	reencoded = append(reencoded, '\n')
	if err := os.WriteFile(c.settingsPath(), reencoded, 0o644); err != nil {
		t.Fatalf("write reencoded: %v", err)
	}
	// Status must still report Current after the round-trip.
	got := c.Status()
	if got.Status != StatusCurrent {
		t.Errorf("round-trip lost tag, status=%+v", got)
	}
}

func TestScriptHash(t *testing.T) {
	if h := ScriptHash("claude"); len(h) != 64 {
		t.Errorf("script hash length: %d", len(h))
	}
	if ScriptHash("claude") == ScriptHash("codex") {
		t.Error("per-agent script hashes should differ")
	}
}

func TestManagerInstallAllStopsAtPiStub(t *testing.T) {
	m := NewManager()
	// Replace installers that can write real config with temp-rooted
	// ones. Pi remains stubbed until PR-C.
	m.Register(&ClaudeInstaller{Home: t.TempDir()})
	m.Register(&CodexInstaller{Home: t.TempDir()})
	// Install all: pi stub will fail.
	err := m.Install(nil)
	if err == nil {
		t.Fatal("expected pi stub to fail in PR-A")
	}
	if !contains(err.Error(), "not yet implemented") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestManagerInstallClaudeOnly(t *testing.T) {
	m := NewManager()
	tmp := t.TempDir()
	m.Register(&ClaudeInstaller{Home: tmp})
	if err := m.Install([]string{"claude"}); err != nil {
		t.Fatalf("claude install: %v", err)
	}
	if _, err := os.Stat(filepath.Join(tmp, "hooks", "party-cli-state.sh")); err != nil {
		t.Errorf("script not written: %v", err)
	}
}
