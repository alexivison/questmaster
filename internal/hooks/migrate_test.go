package hooks

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

var fixedMigrationTime = time.Date(2026, time.May, 22, 12, 0, 0, 0, time.UTC)

func fixedMigrationNow() time.Time { return fixedMigrationTime }

func testConfigFileName() string { return "config" + "." + "toml" }

type syntheticLegacyHome struct {
	home       string
	xdg        string
	claudeHome string
	codexHome  string
	piHome     string
}

func newSyntheticLegacyHome(t *testing.T) syntheticLegacyHome {
	t.Helper()
	home := t.TempDir()
	xdg := filepath.Join(home, ".config")
	env := syntheticLegacyHome{
		home:       home,
		xdg:        xdg,
		claudeHome: filepath.Join(home, ".claude"),
		codexHome:  filepath.Join(home, ".codex"),
		piHome:     filepath.Join(home, ".pi"),
	}
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", xdg)
	t.Setenv("CLAUDE_CONFIG_DIR", env.claudeHome)
	t.Setenv("CODEX_HOME", env.codexHome)
	t.Setenv("PI_HOME", env.piHome)
	t.Setenv("QUESTMASTER_STATE_ROOT", "")
	t.Setenv("PARTY_STATE_ROOT", "")
	return env
}

func seedSyntheticLegacyInstall(t *testing.T, env syntheticLegacyHome) {
	t.Helper()
	writeFile(t, filepath.Join(env.home, ".party-state", "party-old", "state.json"), `{"session_id":"party-old"}`+"\n")
	writeFile(t, filepath.Join(env.xdg, "party-cli", testConfigFileName()), "# legacy config\n")

	claudeScript := filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh")
	writeFile(t, claudeScript, RenderLegacyScript("claude"))
	writeJSON(t, filepath.Join(env.claudeHome, "settings.json"), map[string]any{
		"hooks": map[string]any{
			"SessionStart": []any{
				map[string]any{"hooks": []any{map[string]any{"type": "command", "command": "~/.claude/hooks/party-cli-state.sh starting", "timeout": float64(5)}}},
				map[string]any{"hooks": []any{map[string]any{"type": "command", "command": "~/.claude/hooks/user-session.sh", "timeout": float64(5)}}},
			},
			"Stop": []any{
				map[string]any{"hooks": []any{map[string]any{"type": "command", "command": "~/.claude/hooks/party-cli-state.sh done", "timeout": float64(5)}}},
			},
		},
	})

	codexScript := filepath.Join(env.codexHome, "hooks", "party-cli-state.sh")
	writeFile(t, codexScript, RenderLegacyScript("codex"))
	writeJSON(t, filepath.Join(env.codexHome, "hooks.json"), map[string]any{
		"hooks": map[string]any{
			"SessionStart": []any{
				map[string]any{"_party_cli": AssetTag, "hooks": []any{map[string]any{"type": "command", "command": codexScript + " starting", "timeout": float64(5)}}},
				map[string]any{"hooks": []any{map[string]any{"type": "command", "command": "user-codex-hook.sh", "timeout": float64(5)}}},
			},
			"Stop": []any{
				map[string]any{"_party_cli": AssetTag, "hooks": []any{map[string]any{"type": "command", "command": codexScript + " done", "timeout": float64(5)}}},
			},
		},
	})
	writeFile(t, filepath.Join(env.codexHome, testConfigFileName()), legacyCodexTrustBlock(t, env.codexHome))

	writeFile(t, filepath.Join(env.piHome, "agent", "extensions", ".party-cli-installed"), QuestmasterSidecarVersion)
}

func TestManagerInstallDryRunDoesNotMutateLegacyHome(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	seedSyntheticLegacyInstall(t, env)
	beforeSettings := readFile(t, filepath.Join(env.claudeHome, "settings.json"))
	beforeHooks := readFile(t, filepath.Join(env.codexHome, "hooks.json"))
	beforeTrust := readFile(t, filepath.Join(env.codexHome, testConfigFileName()))

	var log bytes.Buffer
	m := NewManager()
	if err := m.InstallWithOptions(nil, InstallOptions{DryRun: true, Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("dry-run install: %v", err)
	}

	assertMissing(t, filepath.Join(env.home, ".questmaster-state"))
	assertMissing(t, filepath.Join(env.xdg, "questmaster"))
	assertMissing(t, filepath.Join(env.claudeHome, "hooks", "questmaster-state.sh"))
	assertMissing(t, filepath.Join(env.codexHome, "hooks", "questmaster-state.sh"))
	assertMissing(t, filepath.Join(env.piHome, "agent", "extensions", ".questmaster-installed"))
	assertExists(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.piHome, "agent", "extensions", ".party-cli-installed"))
	if got := readFile(t, filepath.Join(env.claudeHome, "settings.json")); got != beforeSettings {
		t.Fatalf("dry-run mutated Claude settings:\n%s", got)
	}
	if got := readFile(t, filepath.Join(env.codexHome, "hooks.json")); got != beforeHooks {
		t.Fatalf("dry-run mutated Codex hooks:\n%s", got)
	}
	if got := readFile(t, filepath.Join(env.codexHome, testConfigFileName())); got != beforeTrust {
		t.Fatalf("dry-run mutated Codex trust config:\n%s", got)
	}
	for _, want := range []string{
		"dry-run: would copy",
		".party-state",
		".questmaster-state",
		"party-cli-state.sh",
		"questmaster-state.sh",
		".party-cli-installed",
		".questmaster-installed",
	} {
		if !strings.Contains(log.String(), want) {
			t.Fatalf("dry-run log missing %q:\n%s", want, log.String())
		}
	}
}

func TestManagerInstallRejectsUnknownAgentBeforeMigrating(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	seedSyntheticLegacyInstall(t, env)
	var log bytes.Buffer
	m := NewManager()
	err := m.InstallWithOptions([]string{"bogus"}, InstallOptions{Log: &log, Now: fixedMigrationNow})
	if err == nil || !strings.Contains(err.Error(), "unknown agent") {
		t.Fatalf("expected unknown-agent error before migration, got %v", err)
	}
	assertMissing(t, filepath.Join(env.home, ".questmaster-state"))
	assertMissing(t, filepath.Join(env.xdg, "questmaster"))
	assertMissing(t, filepath.Join(env.home, ".party-state", ".moved-to-questmaster"))
	assertExists(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.piHome, "agent", "extensions", ".party-cli-installed"))
	if log.Len() != 0 {
		t.Fatalf("unknown-agent path should not log migration actions, got:\n%s", log.String())
	}
}

func TestManagerInstallSpecificAgentOnlyMigratesThatAgentHooks(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	seedSyntheticLegacyInstall(t, env)
	var log bytes.Buffer
	m := NewManager()
	if err := m.InstallWithOptions([]string{"claude"}, InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("claude install: %v", err)
	}
	assertMissing(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.claudeHome, "hooks", "questmaster-state.sh"))
	assertExists(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh"))
	assertMissing(t, filepath.Join(env.codexHome, "hooks", "questmaster-state.sh"))
	assertExists(t, filepath.Join(env.piHome, "agent", "extensions", ".party-cli-installed"))
	assertMissing(t, filepath.Join(env.piHome, "agent", "extensions", ".questmaster-installed"))
	assertFileContains(t, filepath.Join(env.codexHome, "hooks.json"), "_party_cli")
	assertFileContains(t, filepath.Join(env.codexHome, testConfigFileName()), "BEGIN party-cli codex hook trust")
}

func TestManagerInstallMigratesPristineLegacyHomeAndIsIdempotent(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	seedSyntheticLegacyInstall(t, env)
	var log bytes.Buffer
	m := NewManager()
	if err := m.InstallWithOptions(nil, InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("install: %v", err)
	}

	assertExists(t, filepath.Join(env.home, ".questmaster-state", "party-old", "state.json"))
	assertExists(t, filepath.Join(env.home, ".party-state", ".moved-to-questmaster"))
	assertExists(t, filepath.Join(env.xdg, "questmaster", testConfigFileName()))
	assertExists(t, filepath.Join(env.xdg, "party-cli", ".moved-to-questmaster"))
	assertMissing(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.claudeHome, "hooks", "questmaster-state.sh"))
	assertMissing(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh"))
	assertExists(t, filepath.Join(env.codexHome, "hooks", "questmaster-state.sh"))
	assertMissing(t, filepath.Join(env.piHome, "agent", "extensions", ".party-cli-installed"))
	assertExists(t, filepath.Join(env.piHome, "agent", "extensions", ".questmaster-installed"))

	claudeSettings := readFile(t, filepath.Join(env.claudeHome, "settings.json"))
	if strings.Contains(claudeSettings, "party-cli-state.sh") || !strings.Contains(claudeSettings, "questmaster-state.sh") {
		t.Fatalf("Claude settings were not migrated:\n%s", claudeSettings)
	}
	if !strings.Contains(claudeSettings, "user-session.sh") {
		t.Fatalf("Claude migration removed user hook:\n%s", claudeSettings)
	}
	codexHooks := readFile(t, filepath.Join(env.codexHome, "hooks.json"))
	if strings.Contains(codexHooks, "party-cli-state.sh") || strings.Contains(codexHooks, "_party_cli") {
		t.Fatalf("Codex hooks retained legacy party-cli entries:\n%s", codexHooks)
	}
	if !strings.Contains(codexHooks, "questmaster-state.sh") || !strings.Contains(codexHooks, "_questmaster") {
		t.Fatalf("Codex hooks missing questmaster entries:\n%s", codexHooks)
	}
	codexTrust := readFile(t, filepath.Join(env.codexHome, testConfigFileName()))
	if strings.Contains(codexTrust, "BEGIN party-cli") || !strings.Contains(codexTrust, "BEGIN questmaster") {
		t.Fatalf("Codex trust block was not migrated:\n%s", codexTrust)
	}

	snapshot := snapshotFiles(t,
		filepath.Join(env.home, ".questmaster-state", "party-old", "state.json"),
		filepath.Join(env.xdg, "questmaster", testConfigFileName()),
		filepath.Join(env.claudeHome, "settings.json"),
		filepath.Join(env.claudeHome, "hooks", "questmaster-state.sh"),
		filepath.Join(env.codexHome, "hooks.json"),
		filepath.Join(env.codexHome, testConfigFileName()),
		filepath.Join(env.codexHome, "hooks", "questmaster-state.sh"),
		filepath.Join(env.piHome, "agent", "extensions", ".questmaster-installed"),
	)
	if err := m.InstallWithOptions(nil, InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("second install: %v", err)
	}
	assertSnapshot(t, snapshot)
}

func TestManagerInstallPreservesEditedLegacyScriptsAndCorruptTrustMarker(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	seedSyntheticLegacyInstall(t, env)
	writeFile(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh"), "#!/bin/sh\necho custom claude\n")
	writeFile(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh"), "#!/bin/sh\necho custom codex\n")
	corruptTrust := "# BEGIN party-cli codex hook trust\n[hooks.state.\"broken\"]\ntrusted_hash = \"sha256:edited\"\n"
	writeFile(t, filepath.Join(env.codexHome, testConfigFileName()), corruptTrust)

	var log bytes.Buffer
	m := NewManager()
	if err := m.InstallWithOptions(nil, InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("install: %v", err)
	}

	assertFileContains(t, filepath.Join(env.claudeHome, "hooks", "party-cli-state.sh.bak.20260522"), "custom claude")
	assertFileContains(t, filepath.Join(env.codexHome, "hooks", "party-cli-state.sh.bak.20260522"), "custom codex")
	assertFileContains(t, filepath.Join(env.codexHome, testConfigFileName()), "BEGIN party-cli codex hook trust")
	for _, want := range []string{"preserved your modified party-cli-state.sh", "incomplete legacy Codex trust block"} {
		if !strings.Contains(log.String(), want) {
			t.Fatalf("log missing %q:\n%s", want, log.String())
		}
	}
}

func TestManagerInstallSkipsStateAndConfigCopyWhenNewPathsExist(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	writeFile(t, filepath.Join(env.home, ".party-state", "party-old", "state.json"), "old\n")
	writeFile(t, filepath.Join(env.home, ".questmaster-state", "party-new", "state.json"), "new\n")
	writeFile(t, filepath.Join(env.xdg, "party-cli", testConfigFileName()), "legacy\n")
	writeFile(t, filepath.Join(env.xdg, "questmaster", testConfigFileName()), "current\n")

	var log bytes.Buffer
	m := NewManager()
	if err := m.InstallWithOptions(nil, InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("install: %v", err)
	}
	if got := readFile(t, filepath.Join(env.home, ".questmaster-state", "party-new", "state.json")); got != "new\n" {
		t.Fatalf("new state was overwritten: %q", got)
	}
	if got := readFile(t, filepath.Join(env.xdg, "questmaster", testConfigFileName())); got != "current\n" {
		t.Fatalf("new config was overwritten: %q", got)
	}
	assertMissing(t, filepath.Join(env.home, ".party-state", ".moved-to-questmaster"))
	assertMissing(t, filepath.Join(env.xdg, "party-cli", ".moved-to-questmaster"))
	for _, want := range []string{"both ~/.party-state and ~/.questmaster-state present", "both legacy and questmaster configuration dirs present"} {
		if !strings.Contains(log.String(), want) {
			t.Fatalf("log missing %q:\n%s", want, log.String())
		}
	}
}

func TestMigrateDirectoryCleansTempAfterFailedCopyAndRetries(t *testing.T) {
	env := newSyntheticLegacyHome(t)
	oldPath := filepath.Join(env.home, ".party-state")
	newPath := filepath.Join(env.home, ".questmaster-state")
	writeFile(t, filepath.Join(oldPath, "a-ok.txt"), "ok\n")
	writeFile(t, filepath.Join(oldPath, "z-bad.txt"), "bad\n")

	origCopy := copyDirForMigration
	t.Cleanup(func() { copyDirForMigration = origCopy })
	copyDirForMigration = func(src, dst string) error {
		if err := os.MkdirAll(dst, 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dst, "a-ok.txt"), []byte("ok\n"), 0o644); err != nil {
			return err
		}
		return fmt.Errorf("synthetic copy failure")
	}

	err := migrateStateDir(env.home, InstallOptions{Log: io.Discard, Now: fixedMigrationNow})
	if err == nil || !strings.Contains(err.Error(), "synthetic copy failure") {
		t.Fatalf("expected synthetic copy failure, got %v", err)
	}
	assertMissing(t, newPath)
	assertMissing(t, filepath.Join(filepath.Dir(newPath), ".questmaster-state.tmp"))
	assertMissing(t, filepath.Join(oldPath, ".moved-to-questmaster"))

	copyDirForMigration = origCopy
	if err := migrateStateDir(env.home, InstallOptions{Log: io.Discard, Now: fixedMigrationNow}); err != nil {
		t.Fatalf("retry migration: %v", err)
	}
	assertFileContains(t, filepath.Join(newPath, "a-ok.txt"), "ok")
	assertFileContains(t, filepath.Join(newPath, "z-bad.txt"), "bad")
	assertExists(t, filepath.Join(oldPath, ".moved-to-questmaster"))
}

func TestPiInstallMigratesLegacyMarkers(t *testing.T) {
	for _, tc := range []struct {
		name       string
		oldVersion string
		newVersion string
		wantOld    bool
		wantWarn   bool
	}{
		{name: "old current only", oldVersion: QuestmasterSidecarVersion, wantOld: false},
		{name: "old stale only", oldVersion: "older-version", wantOld: true, wantWarn: true},
		{name: "both same", oldVersion: QuestmasterSidecarVersion, newVersion: QuestmasterSidecarVersion, wantOld: false},
		{name: "both differ", oldVersion: "older-version", newVersion: QuestmasterSidecarVersion, wantOld: true, wantWarn: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			p := &PiInstaller{Home: home}
			oldPath := filepath.Join(home, "agent", "extensions", ".party-cli-installed")
			newPath := filepath.Join(home, "agent", "extensions", ".questmaster-installed")
			if tc.oldVersion != "" {
				writeFile(t, oldPath, tc.oldVersion)
			}
			if tc.newVersion != "" {
				writeFile(t, newPath, tc.newVersion)
			}
			var log bytes.Buffer
			if err := p.InstallWithOptions(InstallOptions{Log: &log, Now: fixedMigrationNow}); err != nil {
				t.Fatalf("install: %v", err)
			}
			assertFileContains(t, newPath, QuestmasterSidecarVersion)
			_, err := os.Stat(oldPath)
			if tc.wantOld && err != nil {
				t.Fatalf("old marker should remain: %v", err)
			}
			if !tc.wantOld && !os.IsNotExist(err) {
				t.Fatalf("old marker should be removed, stat err=%v", err)
			}
			if tc.wantWarn && !strings.Contains(log.String(), "legacy Pi marker") {
				t.Fatalf("expected legacy marker warning, got:\n%s", log.String())
			}
		})
	}
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func writeJSON(t *testing.T, path string, doc any) {
	t.Helper()
	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		t.Fatalf("marshal json: %v", err)
	}
	writeFile(t, path, string(append(data, '\n')))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

func assertExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected %s to exist: %v", path, err)
	}
}

func assertMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected %s to be absent, stat err=%v", path, err)
	}
}

func assertFileContains(t *testing.T, path, needle string) {
	t.Helper()
	if body := readFile(t, path); !strings.Contains(body, needle) {
		t.Fatalf("%s missing %q:\n%s", path, needle, body)
	}
}

func snapshotFiles(t *testing.T, paths ...string) map[string]string {
	t.Helper()
	out := make(map[string]string, len(paths))
	for _, path := range paths {
		out[path] = readFile(t, path)
	}
	return out
}

func assertSnapshot(t *testing.T, snapshot map[string]string) {
	t.Helper()
	for path, want := range snapshot {
		if got := readFile(t, path); got != want {
			t.Fatalf("%s changed across idempotent install:\n--- want\n%s\n--- got\n%s", path, want, got)
		}
	}
}

func legacyCodexTrustBlock(t *testing.T, codexHome string) string {
	t.Helper()
	hooksPath := filepath.Join(codexHome, "hooks.json")
	if resolved, err := filepath.EvalSymlinks(hooksPath); err == nil {
		hooksPath = resolved
	} else if abs, err := filepath.Abs(hooksPath); err == nil {
		hooksPath = abs
	}
	scriptPath := filepath.Join(codexHome, "hooks", "party-cli-state.sh")
	var b strings.Builder
	b.WriteString("# BEGIN party-cli codex hook trust\n")
	for i, event := range codexEvents {
		if i > 0 {
			b.WriteByte('\n')
		}
		key := fmt.Sprintf("%s:%s:0:0", hooksPath, event.HookKey)
		fmt.Fprintf(&b, "[hooks.state.%s]\n", strconv.Quote(key))
		fmt.Fprintf(&b, "trusted_hash = %q\n", testLegacyCommandHookHash(event.HookKey, scriptPath+" "+event.Action))
	}
	b.WriteString("# END party-cli codex hook trust\n")
	return b.String()
}

func testLegacyCommandHookHash(eventName, command string) string {
	identity := map[string]any{
		"event_name": eventName,
		"hooks": []any{
			map[string]any{
				"async":   false,
				"command": command,
				"timeout": codexHookTimeoutSec,
				"type":    "command",
			},
		},
	}
	serialized, _ := json.Marshal(identity)
	sum := sha256.Sum256(serialized)
	return "sha256:" + hex.EncodeToString(sum[:])
}
