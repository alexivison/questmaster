package hooks

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/BurntSushi/toml"
)

func newTestCodexInstaller(t *testing.T) *CodexInstaller {
	t.Helper()
	return &CodexInstaller{Home: t.TempDir()}
}

func writeCodexConfig(t *testing.T, c *CodexInstaller, hooksFeature bool) {
	t.Helper()
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir codex home: %v", err)
	}
	value := "false"
	if hooksFeature {
		value = "true"
	}
	body := []byte("[features]\nhooks = " + value + "\n")
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

func codexHookMap(t *testing.T, doc map[string]interface{}) map[string]interface{} {
	t.Helper()
	hooks, ok := doc["hooks"].(map[string]interface{})
	if !ok {
		t.Fatalf("hooks wrong shape: %+v", doc["hooks"])
	}
	return hooks
}

func taggedCodexEntries(t *testing.T, c *CodexInstaller) []map[string]interface{} {
	t.Helper()
	return c.taggedEntries(readCodexHooks(t, c))
}

func readCodexTrustState(t *testing.T, c *CodexInstaller) map[string]string {
	t.Helper()
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config.toml: %v", err)
	}
	var cfg struct {
		Hooks struct {
			State map[string]struct {
				TrustedHash string `toml:"trusted_hash"`
			} `toml:"state"`
		} `toml:"hooks"`
	}
	if _, err := toml.Decode(string(data), &cfg); err != nil {
		t.Fatalf("parse config.toml: %v", err)
	}
	out := make(map[string]string, len(cfg.Hooks.State))
	for key, state := range cfg.Hooks.State {
		out[key] = state.TrustedHash
	}
	return out
}

func assertCodexTrustStateKeysUnique(t *testing.T, body string) {
	t.Helper()
	counts := make(map[string]int)
	for _, line := range splitLines(body) {
		if key, ok := codexTrustStateHeaderKey(line); ok {
			counts[key]++
		}
	}
	for key, count := range counts {
		if count > 1 {
			t.Fatalf("duplicate hooks.state key %q appears %d times in config:\n%s", key, count, body)
		}
	}
}

func countCodexTrustStateHeader(body, key string) int {
	count := 0
	for _, line := range splitLines(body) {
		if got, ok := codexTrustStateHeaderKey(line); ok && got == key {
			count++
		}
	}
	return count
}

func TestCodexEventsIncludesPermissionRequest(t *testing.T) {
	for _, entry := range codexEvents {
		if entry.Event != "PermissionRequest" {
			continue
		}
		if entry.HookKey != "permission_request" {
			t.Fatalf("PermissionRequest HookKey: want %q got %q", "permission_request", entry.HookKey)
		}
		if entry.Action != "permission" {
			t.Fatalf("PermissionRequest Action: want %q got %q", "permission", entry.Action)
		}
		return
	}
	t.Fatal("codexEvents missing PermissionRequest")
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
	for _, entry := range entries {
		if entry["_party_cli"] != AssetTag {
			t.Errorf("missing party tag: %+v", entry)
		}
	}
	doc := readCodexHooks(t, c)
	hooks := codexHookMap(t, doc)
	permissionEvent := codexEntry{Event: "PermissionRequest", HookKey: "permission_request", Action: "permission"}
	if !c.eventEntryCurrent(hooks[permissionEvent.Event], permissionEvent) {
		t.Errorf("missing current PermissionRequest hook entry: %+v", hooks[permissionEvent.Event])
	}

	state := readCodexTrustState(t, c)
	trustEntries, err := c.trustEntries()
	if err != nil {
		t.Fatalf("trust entries: %v", err)
	}
	sawPermissionTrust := false
	for _, entry := range trustEntries {
		if state[entry.Key] != entry.Hash {
			t.Errorf("trusted state mismatch for %s: got %q want %q", entry.Key, state[entry.Key], entry.Hash)
		}
		if strings.HasSuffix(entry.Key, ":permission_request:0:0") {
			sawPermissionTrust = true
		}
	}
	if !sawPermissionTrust {
		t.Fatal("trust state missing permission_request entry")
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
	firstConfig, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config after first install: %v", err)
	}
	assertCodexTrustStateKeysUnique(t, string(firstConfig))
	if err := c.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(c.hooksPath())
	if err != nil {
		t.Fatalf("read after second install: %v", err)
	}
	secondConfig, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config after second install: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("re-install changed hooks.json:\n--- first\n%s\n--- second\n%s", first, second)
	}
	if string(firstConfig) != string(secondConfig) {
		t.Errorf("re-install changed config.toml:\n--- first\n%s\n--- second\n%s", firstConfig, secondConfig)
	}
	assertCodexTrustStateKeysUnique(t, string(secondConfig))
}

func TestCodexTagRoundTripPreservesCodexSchema(t *testing.T) {
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
		hooks, ok := entry["hooks"].([]interface{})
		if !ok || len(hooks) != 1 {
			t.Errorf("round-trip hook handler wrong shape: %+v", entry)
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
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	updated := strings.Replace(string(data), `trusted_hash = "sha256:`, `trusted_hash = "sha256:not-`, 1)
	if err := os.WriteFile(c.configPath(), []byte(updated), 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

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
	writeCodexConfig(t, c, true)

	if got := c.Status(); got.Status != StatusUntrusted {
		t.Errorf("status: %+v", got)
	}
}

func TestCodexInstallRecoversDuplicateManagedTrustState(t *testing.T) {
	c := newTestCodexInstaller(t)
	if err := os.MkdirAll(c.Home, 0o755); err != nil {
		t.Fatalf("mkdir codex home: %v", err)
	}
	if err := os.WriteFile(c.hooksPath(), nil, 0o644); err != nil {
		t.Fatalf("seed hooks.json: %v", err)
	}
	trustEntries, err := c.trustEntries()
	if err != nil {
		t.Fatalf("trust entries: %v", err)
	}
	managed := trustEntries[2]
	foreignKey := filepath.Join(c.Home, "hooks.json") + ":legacy:0:0"
	foreignHash := "sha256:foreign"
	seed := fmt.Sprintf(`[features]
hooks = true

[hooks.state.%s]
trusted_hash = "sha256:stale-outside"

[hooks.state.%s]
trusted_hash = %q

%s
[hooks.state.%s]
trusted_hash = "sha256:stale-inside"
%s
`, strconv.Quote(managed.Key), strconv.Quote(foreignKey), foreignHash, codexTrustBegin, strconv.Quote(managed.Key), codexTrustEnd)
	if err := os.WriteFile(c.configPath(), []byte(seed), 0o644); err != nil {
		t.Fatalf("seed config.toml: %v", err)
	}

	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}

	after, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config after install: %v", err)
	}
	body := string(after)
	assertCodexTrustStateKeysUnique(t, body)
	if count := countCodexTrustStateHeader(body, managed.Key); count != 1 {
		t.Fatalf("managed trust key count: want 1 got %d\n%s", count, body)
	}
	if count := countCodexTrustStateHeader(body, foreignKey); count != 1 {
		t.Fatalf("foreign trust key count: want 1 got %d\n%s", count, body)
	}
	state := readCodexTrustState(t, c)
	if state[managed.Key] != managed.Hash {
		t.Fatalf("managed trust hash: got %q want %q", state[managed.Key], managed.Hash)
	}
	if state[foreignKey] != foreignHash {
		t.Fatalf("foreign trust hash: got %q want %q", state[foreignKey], foreignHash)
	}
	if got := c.Status(); got.Status != StatusCurrent {
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
	hooks := codexHookMap(t, doc)
	preToolUse, _ := hooks["PreToolUse"].([]interface{})
	preToolUse = append(preToolUse, map[string]interface{}{
		"hooks": []interface{}{
			map[string]interface{}{
				"type":    "command",
				"command": "user-hook.sh arg",
			},
		},
	})
	hooks["PreToolUse"] = preToolUse
	writeCodexHooks(t, c, doc)

	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(c.scriptPath()); err == nil {
		t.Error("script not removed")
	}
	got := readCodexHooks(t, c)
	gotHooks := codexHookMap(t, got)
	if _, exists := gotHooks["PermissionRequest"]; exists {
		t.Errorf("PermissionRequest party-cli entry survived uninstall: %+v", gotHooks["PermissionRequest"])
	}
	remaining, _ := gotHooks["PreToolUse"].([]interface{})
	if len(remaining) != 1 {
		t.Fatalf("want one untagged entry, got %d: %+v", len(remaining), remaining)
	}
	entry := remaining[0].(map[string]interface{})
	if entry["_party_cli"] == AssetTag {
		t.Error("party-cli entry survived uninstall")
	}
	handlers := entry["hooks"].([]interface{})
	if handlers[0].(map[string]interface{})["command"] != "user-hook.sh arg" {
		t.Errorf("wrong surviving entry: %+v", entry)
	}
}

func TestCodexStatusOutdatedWhenHooksFeatureDisabled(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, false)
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if got := c.Status(); got.Status != StatusOutdated {
		t.Errorf("disabled hooks feature should be Outdated: %+v", got)
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

func TestCodexUninstallRemovesOnlyManagedTrustBlock(t *testing.T) {
	c := newTestCodexInstaller(t)
	writeCodexConfig(t, c, true)
	original := "[features]\nhooks = true\n\n[projects.\"/tmp\"]\ntrust_level = \"trusted\"\n"
	if err := os.WriteFile(c.configPath(), []byte(original), 0o644); err != nil {
		t.Fatalf("seed config: %v", err)
	}
	if err := c.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	before, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config before uninstall: %v", err)
	}
	if !strings.Contains(string(before), codexTrustBegin) {
		t.Fatalf("install did not add trust block:\n%s", before)
	}
	if err := c.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	after, err := os.ReadFile(c.configPath())
	if err != nil {
		t.Fatalf("read config after uninstall: %v", err)
	}
	if string(after) != original {
		t.Errorf("uninstall did not restore original config:\n%s", after)
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
		"hooks": map[string]interface{}{
			"Stop": []interface{}{
				map[string]interface{}{
					"hooks": []interface{}{
						map[string]interface{}{
							"type":    "command",
							"command": "user-stop.sh",
						},
					},
				},
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
