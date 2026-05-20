package hooks

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func newTestCodexInstaller(t *testing.T) *CodexInstaller {
	t.Helper()
	return &CodexInstaller{Home: t.TempDir()}
}

func writeCodexConfig(t *testing.T, c *CodexInstaller, pluginHooks bool) {
	t.Helper()
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir codex home: %v", err)
	}
	value := "false"
	if pluginHooks {
		value = "true"
	}
	body := []byte("[features]\nplugin_hooks = " + value + "\n")
	if err := os.WriteFile(c.configPath(), body, 0o644); err != nil {
		t.Fatalf("write config.toml: %v", err)
	}
}

func readCodexHooks(t *testing.T, c *CodexInstaller) map[string]interface{} {
	t.Helper()
	data, err := os.ReadFile(c.hooksPath())
	if err != nil {
		t.Fatalf("read hooks.json: %v", err)
	}
	var out map[string]interface{}
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatalf("parse hooks.json: %v", err)
	}
	return out
}

func writeCodexHooks(t *testing.T, c *CodexInstaller, doc map[string]interface{}) {
	t.Helper()
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatalf("encode hooks.json: %v", err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(c.hooksPath(), data, 0o644); err != nil {
		t.Fatalf("write hooks.json: %v", err)
	}
}

func codexHookArray(t *testing.T, doc map[string]interface{}) []interface{} {
	t.Helper()
	hooks, ok := doc["hooks"].([]interface{})
	if !ok {
		t.Fatalf("hooks wrong shape: %+v", doc["hooks"])
	}
	return hooks
}

func taggedCodexEntries(t *testing.T, c *CodexInstaller) []map[string]interface{} {
	t.Helper()
	return c.taggedEntries(readCodexHooks(t, c))
}

func TestCodexInstallCreatesScriptAndHooks(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	body, err := os.ReadFile(c.scriptPath())
	if err != nil {
		t.Fatalf("read script: %v", err)
	}
	if string(body) != RenderScript("codex") {
		t.Errorf("script body mismatch:\n%s", body)
	}
	info, err := os.Stat(c.scriptPath())
	if err != nil {
		t.Fatalf("stat script: %v", err)
	}
	if info.Mode()&0o111 == 0 {
		t.Error("script not executable")
	}

	entries := taggedCodexEntries(t, c)
	if len(entries) != len(codexEvents) {
		t.Fatalf("tagged entries: want %d got %d", len(codexEvents), len(entries))
	}
	wantHash := ScriptHash("codex")
	for _, entry := range entries {
		if entry["_party_cli"] != AssetTag {
			t.Errorf("missing party tag: %+v", entry)
		}
		if entry["trusted_hash"] != wantHash {
			t.Errorf("trusted_hash mismatch: %+v", entry)
		}
	}
	if got := c.Status(); got.Status != StatusCurrent {
		t.Errorf("status: %+v", got)
	}
}

func TestCodexInstallIsIdempotent(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(c.hooksPath())
	if err != nil {
		t.Fatalf("read after first install: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(c.hooksPath())
	if err != nil {
		t.Fatalf("read after second install: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("re-install changed hooks.json:\n--- first\n%s\n--- second\n%s", first, second)
	}
}

func TestCodexTagRoundTripPreservesTrustFields(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	doc := readCodexHooks(t, c)
	writeCodexHooks(t, c, doc)

	for _, entry := range taggedCodexEntries(t, c) {
		if entry["_party_cli"] != AssetTag {
			t.Errorf("round-trip lost party tag: %+v", entry)
		}
		if entry["trusted_hash"] != ScriptHash("codex") {
			t.Errorf("round-trip lost trusted_hash: %+v", entry)
		}
	}
	if got := c.Status(); got.Status != StatusCurrent {
		t.Errorf("round-trip status: %+v", got)
	}
}

func TestCodexTrustedHashMismatchReportsModified(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	doc := readCodexHooks(t, c)
	hooks := codexHookArray(t, doc)
	hooks[0].(map[string]interface{})["trusted_hash"] = "not-the-script-hash"
	writeCodexHooks(t, c, doc)

	if got := c.Status(); got.Status != StatusModified {
		t.Errorf("status: %+v", got)
	}
}

func TestCodexMissingTrustedHashReportsUntrusted(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	doc := readCodexHooks(t, c)
	hooks := codexHookArray(t, doc)
	delete(hooks[0].(map[string]interface{}), "trusted_hash")
	writeCodexHooks(t, c, doc)

	if got := c.Status(); got.Status != StatusUntrusted {
		t.Errorf("status: %+v", got)
	}
}

func TestCodexUninstallPreservesUntaggedEntries(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	doc := readCodexHooks(t, c)
	hooks := codexHookArray(t, doc)
	hooks = append(hooks, map[string]interface{}{
		"event":   "PreToolUse",
		"command": []interface{}{"user-hook.sh", "arg"},
		"stdin":   "passthrough",
	})
	doc["hooks"] = hooks
	writeCodexHooks(t, c, doc)

	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(c.scriptPath()); err == nil {
		t.Error("script not removed")
	}
	got := readCodexHooks(t, c)
	remaining := codexHookArray(t, got)
	if len(remaining) != 1 {
		t.Fatalf("want one untagged entry, got %d: %+v", len(remaining), remaining)
	}
	entry := remaining[0].(map[string]interface{})
	if entry["_party_cli"] == AssetTag {
		t.Error("party-cli entry survived uninstall")
	}
	if entry["command"].([]interface{})[0] != "user-hook.sh" {
		t.Errorf("wrong surviving entry: %+v", entry)
	}
}

func TestCodexStatusOutdatedWhenPluginHooksMissing(t *testing.T) {
	c := newTestCodexInstaller(t)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if got := c.Status(); got.Status != StatusOutdated {
		t.Errorf("missing plugin_hooks should be Outdated: %+v", got)
	}
}

func TestCodexBackupOncePerHooksFile(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	original := []byte(`{"version":1,"hooks":[{"event":"Stop","command":["user.sh"],"stdin":"passthrough"}]}`)
	if err := os.WriteFile(c.hooksPath(), original, 0o644); err != nil {
		t.Fatalf("seed hooks.json: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install 1: %v", err)
	}
	backup1, err := os.ReadFile(c.backupPath())
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if string(backup1) != string(original) {
		t.Errorf("backup mismatch:\n%s\n--\n%s", backup1, original)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install 2: %v", err)
	}
	backup2, _ := os.ReadFile(c.backupPath())
	if string(backup1) != string(backup2) {
		t.Error("install overwrote existing backup")
	}
}

func TestCodexUninstallDoesNotTouchConfigToml(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	before, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config before uninstall: %v", err)
	}
	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	after, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config after uninstall: %v", err)
	}
	if string(before) != string(after) {
		t.Error("uninstall mutated config.toml")
	}
}

func TestCodexInstallPreservesExistingTopLevelFields(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	seed := map[string]interface{}{
		"version": float64(1),
		"note":    "keep me",
		"hooks": []interface{}{
			map[string]interface{}{
				"event":   "Stop",
				"command": []interface{}{"user-stop.sh"},
			},
		},
	}
	writeCodexHooks(t, c, seed)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	got := readCodexHooks(t, c)
	if got["note"] != "keep me" {
		t.Errorf("top-level field not preserved: %+v", got)
	}
	if _, err := os.Stat(filepath.Join(c.Home, "hooks", "party-cli-state.sh")); err != nil {
		t.Errorf("script not written: %v", err)
	}
}
