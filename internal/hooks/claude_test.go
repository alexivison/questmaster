package hooks

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

// findPartyCmd returns the inner-hook command field for the questmaster
// entry matching the given action under event, or "" if missing.
func findPartyCmd(t *testing.T, hooks map[string]interface{}, event, action string) string {
	t.Helper()
	arr, _ := hooks[event].([]interface{})
	suffix := claudeScriptCommandToken + " " + action
	for _, raw := range arr {
		obj, _ := raw.(map[string]interface{})
		inner, _ := obj["hooks"].([]interface{})
		for _, ih := range inner {
			ihObj, _ := ih.(map[string]interface{})
			cmd, _ := ihObj["command"].(string)
			if strings.HasSuffix(cmd, suffix) {
				return cmd
			}
		}
	}
	return ""
}

// settingsTargetsSettingsJSON guards against the regression that
// shipped earlier installer versions: writing to settings.local.json,
// which Claude Code does not load.
func TestClaudeSettingsPathIsSettingsJSON(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if got := filepath.Base(c.settingsPath()); got != "settings.json" {
		t.Errorf("settings target = %q, want settings.json", got)
	}
	if got := filepath.Base(c.backupPath()); got != "settings.json.questmaster.bak" {
		t.Errorf("backup target = %q, want settings.json.questmaster.bak", got)
	}
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
		cmd := findPartyCmd(t, hooks, ev.Event, ev.Action)
		if cmd == "" {
			t.Errorf("missing questmaster entry for %s (action=%s)", ev.Event, ev.Action)
			continue
		}
		want := claudeScriptCommandPath + " " + ev.Action
		if cmd != want {
			t.Errorf("entry for %s command = %q, want %q", ev.Event, cmd, want)
		}
	}
}

// TestClaudeEntriesOmitMatcherField guards the matcher-field shape:
// questmaster entries must NOT carry a `matcher` field, so they sit in a
// separate no-matcher block.
func TestClaudeEntriesOmitMatcherField(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	got := readSettings(t, c)
	hooks, _ := got["hooks"].(map[string]interface{})
	if hooks == nil {
		t.Fatalf("settings missing hooks")
	}
	for _, ev := range claudeEvents {
		arr, _ := hooks[ev.Event].([]interface{})
		var sawParty bool
		for _, raw := range arr {
			obj, _ := raw.(map[string]interface{})
			inner, _ := obj["hooks"].([]interface{})
			isParty := false
			for _, ih := range inner {
				ihObj, _ := ih.(map[string]interface{})
				cmd, _ := ihObj["command"].(string)
				if strings.Contains(cmd, claudeScriptCommandToken) {
					isParty = true
					break
				}
			}
			if !isParty {
				continue
			}
			sawParty = true
			if _, hasMatcher := obj["matcher"]; hasMatcher {
				t.Errorf("entry for %s includes matcher field: %+v", ev.Event, obj)
			}
			if _, hasTag := obj["_questmaster"]; hasTag {
				t.Errorf("entry for %s still carries _questmaster tag: %+v", ev.Event, obj)
			}
		}
		if !sawParty {
			t.Errorf("no questmaster entry found under %s", ev.Event)
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
		t.Errorf("re-install changed settings.json:\n--- first\n%s\n--- second\n%s\n", first, second)
	}
}

func TestClaudeInstallSkipsCurrentSettingsWithoutReformatting(t *testing.T) {
	c := newTestClaudeInstaller(t)
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	original := []byte(`{
  "z_unrelated": {"keep": true},
  "hooks": {
    "Notification": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh blocked", "type": "command"}]}],
    "SessionEnd": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh stopped", "type": "command"}]}],
    "PreToolUse": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh tool_start", "type": "command"}]}],
    "SubagentStop": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh subagent_stop", "type": "command"}]}],
    "SessionStart": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh starting", "type": "command"}]}],
    "Stop": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh done", "type": "command"}]}],
    "PostToolUse": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh tool_end", "type": "command"}]}],
    "UserPromptSubmit": [{"hooks": [{"timeout": 5, "command": "~/.claude/hooks/questmaster-state.sh working", "type": "command"}]}]
  },
  "a_unrelated": ["preserve", "order"]
}
`)
	if err := os.WriteFile(c.settingsPath(), original, 0o644); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	oldTime := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(c.settingsPath(), oldTime, oldTime); err != nil {
		t.Fatalf("chtimes settings: %v", err)
	}
	beforeInfo, err := os.Stat(c.settingsPath())
	if err != nil {
		t.Fatalf("stat before: %v", err)
	}

	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}

	after, err := os.ReadFile(c.settingsPath())
	if err != nil {
		t.Fatalf("read after install: %v", err)
	}
	if !bytes.Equal(original, after) {
		t.Errorf("install reformatted already-current settings.json:\n--- before\n%s\n--- after\n%s", original, after)
	}
	afterInfo, err := os.Stat(c.settingsPath())
	if err != nil {
		t.Fatalf("stat after: %v", err)
	}
	if !afterInfo.ModTime().Equal(beforeInfo.ModTime()) {
		t.Errorf("install rewrote already-current settings.json: mtime before=%s after=%s", beforeInfo.ModTime(), afterInfo.ModTime())
	}
}

func TestClaudeInstallAddsMissingEntriesAndPreservesUnrelatedSettings(t *testing.T) {
	c := newTestClaudeInstaller(t)
	seeded := map[string]interface{}{
		"z_unrelated": "keep me",
		"hooks": map[string]interface{}{
			"PreToolUse": []interface{}{
				map[string]interface{}{
					"matcher": "Bash",
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-pre-tool.sh",
							"timeout": float64(9),
						},
					},
				},
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": claudeScriptCommandPath + " tool_start",
							"timeout": float64(5),
						},
					},
				},
			},
			"Stop": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "~/.claude/hooks/user-stop.sh"},
					},
				},
			},
		},
	}
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	data, _ := json.Marshal(seeded)
	if err := os.WriteFile(c.settingsPath(), data, 0o644); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}

	got := readSettings(t, c)
	if got["z_unrelated"] != "keep me" {
		t.Errorf("top-level setting not preserved: %+v", got)
	}
	hooks, ok := got["hooks"].(map[string]interface{})
	if !ok {
		t.Fatalf("settings missing hooks: %+v", got)
	}
	preToolUse, _ := hooks["PreToolUse"].([]interface{})
	if !entryMatchesField(preToolUse, "matcher", "Bash") || !commandPresent(preToolUse, "user-pre-tool.sh") {
		t.Errorf("unrelated PreToolUse hook not preserved: %+v", preToolUse)
	}
	stop, _ := hooks["Stop"].([]interface{})
	if !commandPresent(stop, "user-stop.sh") {
		t.Errorf("unrelated Stop hook not preserved: %+v", stop)
	}
	for _, ev := range claudeEvents {
		if cmd := findPartyCmd(t, hooks, ev.Event, ev.Action); cmd == "" {
			t.Errorf("missing questmaster entry for %s (action=%s)", ev.Event, ev.Action)
		}
	}
}

// TestClaudeInstallPreservesUserManagedHooks seeds settings.json with
// unrelated hook entries and asserts that install appends questmaster
// entries without disturbing them.
func TestClaudeInstallPreservesUserManagedHooks(t *testing.T) {
	c := newTestClaudeInstaller(t)
	userManaged := map[string]interface{}{
		"effortLevel": "high",
		"hooks": map[string]interface{}{
			"SessionStart": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-session-start.sh",
						},
					},
				},
			},
			"PreToolUse": []interface{}{
				map[string]interface{}{
					"matcher": "Bash",
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-bash-guard.sh",
							"timeout": 10,
						},
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-policy-gate.sh",
							"timeout": 10,
						},
					},
				},
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-tool-state.sh",
							"timeout": 5,
						},
					},
				},
			},
			"Stop": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/user-stop-state.sh",
							"timeout": 5,
						},
					},
				},
			},
		},
	}
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	seeded, _ := json.MarshalIndent(userManaged, "", "  ")
	if err := os.WriteFile(c.settingsPath(), seeded, 0o644); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	got := readSettings(t, c)
	if got["effortLevel"] != "high" {
		t.Error("install clobbered unrelated top-level settings")
	}
	hooks, _ := got["hooks"].(map[string]interface{})

	// SessionStart: user-managed hook still present + questmaster appended.
	startArr, _ := hooks["SessionStart"].([]interface{})
	if len(startArr) != 2 {
		t.Errorf("SessionStart: want 2 entries (user-managed + questmaster), got %d", len(startArr))
	}
	if !commandPresent(startArr, "user-session-start.sh") {
		t.Error("SessionStart: user-managed entry was removed")
	}
	if findPartyCmd(t, hooks, "SessionStart", "starting") == "" {
		t.Error("SessionStart: questmaster entry not appended")
	}

	// PreToolUse: user-managed matcher block, user-managed no-matcher block, and questmaster block.
	preArr, _ := hooks["PreToolUse"].([]interface{})
	if len(preArr) != 3 {
		t.Errorf("PreToolUse: want 3 entries (matcher + user-managed + questmaster), got %d", len(preArr))
	}
	if !entryMatchesField(preArr, "matcher", "Bash") {
		t.Error("PreToolUse: user-managed Bash matcher block was removed")
	}
	if !commandPresent(preArr, "user-bash-guard.sh") {
		t.Error("PreToolUse: user-managed guard hook was removed")
	}
	if !commandPresent(preArr, "user-policy-gate.sh") {
		t.Error("PreToolUse: user-managed policy hook was removed")
	}
	if !commandPresent(preArr, "user-tool-state.sh") {
		t.Error("PreToolUse: user-managed no-matcher hook was removed")
	}
	if findPartyCmd(t, hooks, "PreToolUse", "tool_start") == "" {
		t.Error("PreToolUse: questmaster tool_start entry not appended")
	}

	// Stop: user-managed hook still present + questmaster appended.
	stopArr, _ := hooks["Stop"].([]interface{})
	if len(stopArr) != 2 {
		t.Errorf("Stop: want 2 entries (user-managed + questmaster), got %d", len(stopArr))
	}
	if !commandPresent(stopArr, "user-stop-state.sh") {
		t.Error("Stop: user-managed entry was removed")
	}
	if findPartyCmd(t, hooks, "Stop", "done") == "" {
		t.Error("Stop: questmaster entry not appended")
	}

	// Events without user-managed entries get a single questmaster block.
	for _, ev := range []string{"UserPromptSubmit", "Notification", "SessionEnd", "SubagentStop", "PostToolUse"} {
		arr, _ := hooks[ev].([]interface{})
		if len(arr) != 1 {
			t.Errorf("%s: want 1 questmaster entry, got %d", ev, len(arr))
		}
	}
}

// commandPresent reports whether any inner-hook command in arr contains
// the given substring.
func commandPresent(arr []interface{}, needle string) bool {
	for _, raw := range arr {
		obj, _ := raw.(map[string]interface{})
		inner, _ := obj["hooks"].([]interface{})
		for _, ih := range inner {
			ihObj, _ := ih.(map[string]interface{})
			cmd, _ := ihObj["command"].(string)
			if strings.Contains(cmd, needle) {
				return true
			}
		}
	}
	return false
}

// entryMatchesField reports whether any entry in arr carries key=want.
func entryMatchesField(arr []interface{}, key, want string) bool {
	for _, raw := range arr {
		obj, _ := raw.(map[string]interface{})
		if got, _ := obj[key].(string); got == want {
			return true
		}
	}
	return false
}

func TestClaudeUninstallRemovesOnlyQuestmasterEntries(t *testing.T) {
	c := newTestClaudeInstaller(t)
	// Seed a user-managed hook before install.
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	seeded := map[string]interface{}{
		"hooks": map[string]interface{}{
			"PreToolUse": []interface{}{
				map[string]interface{}{
					"matcher": "Edit",
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "~/.claude/hooks/user-edit.sh"},
					},
				},
			},
			"SessionStart": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{"type": "command", "command": "~/.claude/hooks/user-session-start.sh"},
					},
				},
			},
		},
	}
	data, _ := json.Marshal(seeded)
	if err := os.WriteFile(c.settingsPath(), data, 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(c.scriptPath()); err == nil {
		t.Error("script not removed")
	}
	got := readSettings(t, c)
	hooks, _ := got["hooks"].(map[string]interface{})

	pre, _ := hooks["PreToolUse"].([]interface{})
	if len(pre) != 1 {
		t.Errorf("PreToolUse: want 1 surviving user entry, got %d: %+v", len(pre), pre)
	} else {
		obj := pre[0].(map[string]interface{})
		if obj["matcher"] != "Edit" {
			t.Errorf("wrong surviving entry: %+v", obj)
		}
	}

	start, _ := hooks["SessionStart"].([]interface{})
	if len(start) != 1 {
		t.Errorf("SessionStart: want 1 surviving user-managed entry, got %d: %+v", len(start), start)
	}
	if !commandPresent(start, "user-session-start.sh") {
		t.Error("SessionStart: user-managed entry was destroyed by uninstall")
	}

	// Events that only had questmaster content should now be absent.
	for _, ev := range []string{"UserPromptSubmit", "Stop", "SubagentStop", "Notification", "SessionEnd", "PostToolUse"} {
		if _, present := hooks[ev]; present {
			t.Errorf("%s should be pruned after uninstall, still present: %+v", ev, hooks[ev])
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

// TestRenderedScriptEmitsJSON checks that the embedded shell script
// (a) does not call `exec` (which would prevent subsequent hooks
// from executing) and (b) ends with `echo '{}'` so Claude Code's
// JSON-shape expectation is satisfied for advisory hooks.
func TestRenderedScriptEmitsJSON(t *testing.T) {
	for _, agent := range []string{"claude", "codex", "pi"} {
		body := RenderScript(agent)
		if strings.Contains(body, "exec questmaster") {
			t.Errorf("%s script still uses exec form:\n%s", agent, body)
		}
		want := `"$QM_BIN" hook --session "$SESSION_ID" ` + agent + ` "$1"`
		if !strings.Contains(body, want) {
			t.Errorf("rendered %s script missing %q:\n%s", agent, want, body)
		}
		if !strings.Contains(body, `command -v questmaster`) || !strings.Contains(body, `command -v qm`) {
			t.Errorf("rendered %s script missing questmaster/qm binary fallback:\n%s", agent, body)
		}
		if !strings.Contains(body, `echo '{}'`) {
			t.Errorf("%s script does not emit JSON sentinel:\n%s", agent, body)
		}
		if strings.Contains(body, "__AGENT__") {
			t.Errorf("rendered %s script still contains placeholder", agent)
		}
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

func TestManagerInstallAllWithTempInstallers(t *testing.T) {
	setSyntheticManagerEnv(t)
	m := NewManager()
	// Replace installers with temp-rooted ones so the all-agent path never
	// touches real user config.
	m.Register(&ClaudeInstaller{Home: t.TempDir()})
	m.Register(&CodexInstaller{Home: t.TempDir()})
	m.Register(&PiInstaller{Home: t.TempDir()})
	if err := m.Install(nil); err != nil {
		t.Fatalf("install all: %v", err)
	}
}

func TestManagerInstallClaudeOnly(t *testing.T) {
	setSyntheticManagerEnv(t)
	m := NewManager()
	tmp := t.TempDir()
	m.Register(&ClaudeInstaller{Home: tmp})
	if err := m.Install([]string{"claude"}); err != nil {
		t.Fatalf("claude install: %v", err)
	}
	if _, err := os.Stat(filepath.Join(tmp, "hooks", "questmaster-state.sh")); err != nil {
		t.Errorf("script not written: %v", err)
	}
}

func setSyntheticManagerEnv(t *testing.T) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude"))
	t.Setenv("CODEX_HOME", filepath.Join(home, ".codex"))
	t.Setenv("PI_HOME", filepath.Join(home, ".pi"))
	t.Setenv("QUESTMASTER_STATE_ROOT", "")
}
