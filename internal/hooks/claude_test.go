package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
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

// findPartyCmd returns the inner-hook command field for the party-cli
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
	if got := filepath.Base(c.backupPath()); got != "settings.json.party-cli.bak" {
		t.Errorf("backup target = %q, want settings.json.party-cli.bak", got)
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
			t.Errorf("missing party-cli entry for %s (action=%s)", ev.Event, ev.Action)
			continue
		}
		want := claudeScriptCommandPath + " " + ev.Action
		if cmd != want {
			t.Errorf("entry for %s command = %q, want %q", ev.Event, cmd, want)
		}
	}
}

// TestClaudeEntriesOmitMatcherField guards the matcher-field shape:
// party-cli entries must NOT carry a `matcher` field. They mirror the
// canonical primary-state.sh pattern of a separate no-matcher block.
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
			if _, hasTag := obj["_party_cli"]; hasTag {
				t.Errorf("entry for %s still carries _party_cli tag: %+v", ev.Event, obj)
			}
		}
		if !sawParty {
			t.Errorf("no party-cli entry found under %s", ev.Event)
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

// TestClaudeInstallPreservesCanonicalHooks seeds settings.json with the
// canonical hook entries (session-cleanup.sh on SessionStart, the Bash
// matcher block with worktree-guard.sh + companion-gate.sh on
// PreToolUse, primary-state.sh on Stop) and asserts that after install
// every canonical entry is intact and party-cli entries have been
// appended alongside.
func TestClaudeInstallPreservesCanonicalHooks(t *testing.T) {
	c := newTestClaudeInstaller(t)
	canonical := map[string]interface{}{
		"effortLevel": "high",
		"hooks": map[string]interface{}{
			"SessionStart": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/session-cleanup.sh",
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
							"command": "~/.claude/hooks/worktree-guard.sh",
							"timeout": 10,
						},
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/companion-gate.sh",
							"timeout": 10,
						},
					},
				},
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "~/.claude/hooks/primary-state.sh",
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
							"command": "~/.claude/hooks/primary-state.sh",
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
	seeded, _ := json.MarshalIndent(canonical, "", "  ")
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

	// SessionStart: canonical session-cleanup.sh still present + party-cli appended.
	startArr, _ := hooks["SessionStart"].([]interface{})
	if len(startArr) != 2 {
		t.Errorf("SessionStart: want 2 entries (canonical + party-cli), got %d", len(startArr))
	}
	if !commandPresent(startArr, "session-cleanup.sh") {
		t.Error("SessionStart: canonical session-cleanup.sh entry was removed")
	}
	if findPartyCmd(t, hooks, "SessionStart", "starting") == "" {
		t.Error("SessionStart: party-cli entry not appended")
	}

	// PreToolUse: canonical Bash matcher block AND no-matcher primary-state.sh block AND party-cli block.
	preArr, _ := hooks["PreToolUse"].([]interface{})
	if len(preArr) != 3 {
		t.Errorf("PreToolUse: want 3 entries (Bash matcher + primary-state + party-cli), got %d", len(preArr))
	}
	if !entryMatchesField(preArr, "matcher", "Bash") {
		t.Error("PreToolUse: canonical Bash matcher block was removed")
	}
	if !commandPresent(preArr, "worktree-guard.sh") {
		t.Error("PreToolUse: canonical worktree-guard.sh was removed")
	}
	if !commandPresent(preArr, "companion-gate.sh") {
		t.Error("PreToolUse: canonical companion-gate.sh was removed")
	}
	if !commandPresent(preArr, "primary-state.sh") {
		t.Error("PreToolUse: canonical primary-state.sh was removed")
	}
	if findPartyCmd(t, hooks, "PreToolUse", "tool_start") == "" {
		t.Error("PreToolUse: party-cli tool_start entry not appended")
	}

	// Stop: canonical primary-state.sh still present + party-cli appended.
	stopArr, _ := hooks["Stop"].([]interface{})
	if len(stopArr) != 2 {
		t.Errorf("Stop: want 2 entries (canonical + party-cli), got %d", len(stopArr))
	}
	if !commandPresent(stopArr, "primary-state.sh") {
		t.Error("Stop: canonical primary-state.sh entry was removed")
	}
	if findPartyCmd(t, hooks, "Stop", "done") == "" {
		t.Error("Stop: party-cli entry not appended")
	}

	// Events without canonical entries get a single party-cli block.
	for _, ev := range []string{"UserPromptSubmit", "Notification", "SessionEnd", "SubagentStop", "PostToolUse"} {
		arr, _ := hooks[ev].([]interface{})
		if len(arr) != 1 {
			t.Errorf("%s: want 1 party-cli entry, got %d", ev, len(arr))
		}
	}
}

// commandPresent reports whether any inner-hook command in arr contains
// the given substring (e.g. "session-cleanup.sh").
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

func TestClaudeUninstallRemovesOnlyPartyCLIEntries(t *testing.T) {
	c := newTestClaudeInstaller(t)
	// Seed canonical hooks before install.
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
						map[string]interface{}{"type": "command", "command": "~/.claude/hooks/session-cleanup.sh"},
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
		t.Errorf("SessionStart: want 1 surviving canonical entry, got %d: %+v", len(start), start)
	}
	if !commandPresent(start, "session-cleanup.sh") {
		t.Error("SessionStart: canonical session-cleanup.sh entry was destroyed by uninstall")
	}

	// Events that only had party-cli content should now be absent.
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
		if strings.Contains(body, "exec party-cli") {
			t.Errorf("%s script still uses exec form:\n%s", agent, body)
		}
		want := `party-cli hook ` + agent + ` "$1"`
		if !strings.Contains(body, want) {
			t.Errorf("rendered %s script missing %q:\n%s", agent, want, body)
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
