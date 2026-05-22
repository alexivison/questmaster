package hooks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"
)

const (
	legacyScriptName      = "party-cli-state.sh"
	questmasterScriptName = "questmaster-state.sh"
	migrationMarkerName   = ".moved-to-questmaster"

	legacyCodexTrustBegin = "# BEGIN party-cli codex hook trust"
	legacyCodexTrustEnd   = "# END party-cli codex hook trust"
)

const legacyScriptTemplate = `#!/bin/sh
# party-cli state hook v1 — managed by ` + "`party-cli hooks install`" + `
# Generated; do not edit. Re-install via ` + "`party-cli hooks install`" + ` to refresh.
if [ -n "$PARTY_SESSION" ] && command -v party-cli >/dev/null 2>&1; then
    party-cli hook __AGENT__ "$1" >/dev/null 2>&1 || true
fi
echo '{}'
`

// RenderLegacyScript renders the pristine party-cli hook script so migration can
// distinguish managed files from user edits after the asset rename.
func RenderLegacyScript(agent string) string {
	return strings.ReplaceAll(legacyScriptTemplate, "__AGENT__", agent)
}

func migrateLegacyInstall(selectedAgents []string, opts InstallOptions) error {
	opts = opts.normalized()
	home := os.Getenv("HOME")
	if home == "" {
		if resolved, err := os.UserHomeDir(); err == nil {
			home = resolved
		}
	}
	if home == "" {
		return nil
	}
	if err := migrateStateDir(home, opts); err != nil {
		return err
	}
	if err := migrateConfigDir(home, opts); err != nil {
		return err
	}
	selected := make(map[string]struct{}, len(selectedAgents))
	for _, name := range selectedAgents {
		selected[name] = struct{}{}
	}
	if _, ok := selected["claude"]; ok {
		if err := migrateClaudeLegacy(NewClaudeInstaller(""), opts); err != nil {
			return err
		}
	}
	if _, ok := selected["codex"]; ok {
		if err := migrateCodexLegacy(NewCodexInstaller(""), opts); err != nil {
			return err
		}
	}
	return nil
}

func migrateStateDir(home string, opts InstallOptions) error {
	oldPath := filepath.Join(home, ".party-state")
	newPath := filepath.Join(home, ".questmaster-state")
	return migrateDirectory(oldPath, newPath, "questmaster: both ~/.party-state and ~/.questmaster-state present; using ~/.questmaster-state", opts)
}

func migrateConfigDir(home string, opts InstallOptions) error {
	base := filepath.Join(home, ".config")
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		base = xdg
	}
	oldPath := filepath.Join(base, "party-cli")
	newPath := filepath.Join(base, "questmaster")
	return migrateDirectory(oldPath, newPath, "questmaster: both legacy and questmaster config dirs present; using questmaster config", opts)
}

func migrateDirectory(oldPath, newPath, bothWarning string, opts InstallOptions) error {
	oldInfo, oldErr := os.Stat(oldPath)
	if errors.Is(oldErr, os.ErrNotExist) {
		return nil
	}
	if oldErr != nil {
		return fmt.Errorf("stat legacy path %s: %w", oldPath, oldErr)
	}
	if !oldInfo.IsDir() {
		return nil
	}
	newInfo, newErr := os.Stat(newPath)
	switch {
	case newErr == nil && newInfo.IsDir():
		logf(opts, bothWarning)
		return nil
	case newErr == nil:
		return fmt.Errorf("questmaster migration target %s exists and is not a directory", newPath)
	case !errors.Is(newErr, os.ErrNotExist):
		return fmt.Errorf("stat migration target %s: %w", newPath, newErr)
	}
	tmpPath := filepath.Join(filepath.Dir(newPath), "."+filepath.Base(newPath)+".tmp")
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would copy %s to %s", oldPath, tmpPath)
		logf(opts, "questmaster: dry-run: would rename %s to %s", tmpPath, newPath)
		logf(opts, "questmaster: dry-run: would write %s", filepath.Join(oldPath, migrationMarkerName))
		return nil
	}
	if err := os.RemoveAll(tmpPath); err != nil {
		return fmt.Errorf("remove stale migration temp dir %s: %w", tmpPath, err)
	}
	if err := copyDirForMigration(oldPath, tmpPath); err != nil {
		_ = os.RemoveAll(tmpPath)
		return fmt.Errorf("copy %s to %s: %w", oldPath, newPath, err)
	}
	if err := os.Rename(tmpPath, newPath); err != nil {
		_ = os.RemoveAll(tmpPath)
		return fmt.Errorf("rename %s to %s: %w", tmpPath, newPath, err)
	}
	marker := filepath.Join(oldPath, migrationMarkerName)
	body := fmt.Sprintf("moved to %s by questmaster; old files preserved for manual cleanup\n", newPath)
	if err := os.WriteFile(marker, []byte(body), 0o644); err != nil {
		_ = os.RemoveAll(newPath)
		return fmt.Errorf("write migration marker %s: %w", marker, err)
	}
	return nil
}

var copyDirForMigration = copyDir

func copyDir(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		if d.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm())
		}
		if !info.Mode().IsRegular() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}

func migrateClaudeLegacy(c *ClaudeInstaller, opts InstallOptions) error {
	if c.Home == "" {
		return nil
	}
	if err := cleanupLegacyScript(c.legacyScriptPath(), RenderLegacyScript("claude"), opts); err != nil {
		return fmt.Errorf("migrate claude legacy script: %w", err)
	}
	return cleanupClaudeLegacySettings(c.settingsPath(), opts)
}

func (c *ClaudeInstaller) legacyScriptPath() string {
	return filepath.Join(c.Home, "hooks", legacyScriptName)
}

func cleanupClaudeLegacySettings(path string, opts InstallOptions) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var settings map[string]interface{}
	if err := json.Unmarshal(data, &settings); err != nil {
		return fmt.Errorf("parse settings.json: %w", err)
	}
	hooks, _ := settings["hooks"].(map[string]interface{})
	if hooks == nil {
		return nil
	}
	changed := false
	for event, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		filtered, dropped := dropClaudeEntriesByToken(arr, legacyScriptName)
		if !dropped {
			continue
		}
		changed = true
		if len(filtered) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = filtered
		}
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	if !changed {
		return nil
	}
	updated, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	updated = append(updated, '\n')
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would remove legacy Claude %s entries from %s", legacyScriptName, path)
		return nil
	}
	return atomicWrite(path, updated)
}

func dropClaudeEntriesByToken(arr []interface{}, token string) ([]interface{}, bool) {
	out := make([]interface{}, 0, len(arr))
	droppedAny := false
	for _, item := range arr {
		obj, ok := item.(map[string]interface{})
		if !ok {
			out = append(out, item)
			continue
		}
		innerHooks, ok := obj["hooks"].([]interface{})
		if !ok {
			out = append(out, item)
			continue
		}
		kept := make([]interface{}, 0, len(innerHooks))
		for _, ih := range innerHooks {
			ihObj, ok := ih.(map[string]interface{})
			if !ok {
				kept = append(kept, ih)
				continue
			}
			cmd, _ := ihObj["command"].(string)
			if strings.Contains(cmd, token) {
				droppedAny = true
				continue
			}
			kept = append(kept, ih)
		}
		if len(kept) == 0 {
			continue
		}
		obj["hooks"] = kept
		out = append(out, obj)
	}
	return out, droppedAny
}

func migrateCodexLegacy(c *CodexInstaller, opts InstallOptions) error {
	if c.Home == "" {
		return nil
	}
	if err := cleanupLegacyScript(c.legacyScriptPath(), RenderLegacyScript("codex"), opts); err != nil {
		return fmt.Errorf("migrate codex legacy script: %w", err)
	}
	if err := cleanupCodexLegacyHooks(c.hooksPath(), opts); err != nil {
		return err
	}
	return cleanupCodexLegacyTrust(c, opts)
}

func (c *CodexInstaller) legacyScriptPath() string {
	return filepath.Join(c.Home, "hooks", legacyScriptName)
}

func cleanupCodexLegacyHooks(path string, opts InstallOptions) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var doc map[string]interface{}
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parse hooks.json: %w", err)
	}
	hooks, _ := doc["hooks"].(map[string]interface{})
	if hooks == nil {
		return nil
	}
	changed := false
	for event, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		filtered, dropped := dropLegacyCodexEntries(arr)
		if !dropped {
			continue
		}
		changed = true
		if len(filtered) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = filtered
		}
	}
	if len(hooks) == 0 {
		delete(doc, "hooks")
	}
	if !changed {
		return nil
	}
	updated, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	updated = append(updated, '\n')
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would remove legacy Codex %s entries from %s", legacyScriptName, path)
		return nil
	}
	return atomicWrite(path, updated)
}

func dropLegacyCodexEntries(arr []interface{}) ([]interface{}, bool) {
	out := make([]interface{}, 0, len(arr))
	droppedAny := false
	for _, item := range arr {
		obj, ok := item.(map[string]interface{})
		if !ok {
			out = append(out, item)
			continue
		}
		tag, _ := obj["_party_cli"].(string)
		if tag != AssetTag || !entryCommandContains(obj, legacyScriptName) {
			out = append(out, item)
			continue
		}
		droppedAny = true
	}
	return out, droppedAny
}

func entryCommandContains(entry map[string]interface{}, token string) bool {
	hooks, _ := entry["hooks"].([]interface{})
	for _, raw := range hooks {
		obj, _ := raw.(map[string]interface{})
		cmd, _ := obj["command"].(string)
		if strings.Contains(cmd, token) {
			return true
		}
	}
	return false
}

func cleanupCodexLegacyTrust(c *CodexInstaller, opts InstallOptions) error {
	data, err := os.ReadFile(c.configPath())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	body := string(data)
	start := strings.Index(body, legacyCodexTrustBegin)
	end := strings.Index(body, legacyCodexTrustEnd)
	if start == -1 && end == -1 {
		return nil
	}
	if start == -1 || end == -1 || end < start {
		logf(opts, "questmaster: incomplete legacy Codex trust block in %s; leaving it unchanged", c.configPath())
		return nil
	}
	blockEnd := end + len(legacyCodexTrustEnd)
	block := body[start:blockEnd]
	entries, err := c.legacyTrustEntries()
	if err != nil {
		return err
	}
	if !codexTrustBlockMatches(block, entries) {
		logf(opts, "questmaster: legacy Codex trust block in %s differs from generated hashes; leaving it unchanged", c.configPath())
		return nil
	}
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would remove legacy Codex trust block from %s", c.configPath())
		return nil
	}
	updated := removeMarkedBlock(body, legacyCodexTrustBegin, legacyCodexTrustEnd)
	return atomicWrite(c.configPath(), []byte(updated))
}

func (c *CodexInstaller) legacyTrustEntries() ([]codexTrustEntry, error) {
	sourcePath, err := c.codexSourcePath()
	if err != nil {
		return nil, err
	}
	out := make([]codexTrustEntry, 0, len(codexEvents))
	for _, event := range codexEvents {
		out = append(out, codexTrustEntry{
			Key:  fmt.Sprintf("%s:%s:0:0", sourcePath, event.HookKey),
			Hash: legacyCommandHookHash(event.HookKey, fmt.Sprintf("%s %s", c.legacyScriptPath(), event.Action)),
		})
	}
	return out, nil
}

func legacyCommandHookHash(eventName, command string) string {
	identity := map[string]interface{}{
		"event_name": eventName,
		"hooks": []interface{}{
			map[string]interface{}{
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

func codexTrustBlockMatches(block string, entries []codexTrustEntry) bool {
	var cfg struct {
		Hooks struct {
			State map[string]struct {
				TrustedHash string `toml:"trusted_hash"`
			} `toml:"state"`
		} `toml:"hooks"`
	}
	if _, err := toml.Decode(block, &cfg); err != nil {
		return false
	}
	if len(cfg.Hooks.State) != len(entries) {
		return false
	}
	for _, entry := range entries {
		state, ok := cfg.Hooks.State[entry.Key]
		if !ok || state.TrustedHash != entry.Hash {
			return false
		}
	}
	return true
}

func removeMarkedBlock(body, begin, endMarker string) string {
	start := strings.Index(body, begin)
	if start == -1 {
		return body
	}
	relEnd := strings.Index(body[start:], endMarker)
	if relEnd == -1 {
		return body
	}
	end := start + relEnd + len(endMarker)
	for end < len(body) && (body[end] == '\n' || body[end] == '\r') {
		end++
	}
	removeStart := start
	if removeStart >= 2 && body[removeStart-1] == '\n' && body[removeStart-2] == '\n' {
		removeStart--
	}
	return body[:removeStart] + body[end:]
}

func cleanupLegacyScript(path, pristine string, opts InstallOptions) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if string(data) == pristine {
		if opts.DryRun {
			logf(opts, "questmaster: dry-run: would remove pristine legacy hook script %s", path)
			return nil
		}
		return os.Remove(path)
	}
	backup := path + ".bak." + opts.normalized().Now().Format("20060102")
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would preserve your modified %s as %s", filepath.Base(path), backup)
		return nil
	}
	if err := os.Rename(path, backup); err != nil {
		return err
	}
	logf(opts, "questmaster: preserved your modified %s as %s", filepath.Base(path), backup)
	return nil
}

func renderLegacyCodexTrustBlock(entries []codexTrustEntry) string {
	var b strings.Builder
	b.WriteString(legacyCodexTrustBegin)
	b.WriteByte('\n')
	for i, entry := range entries {
		if i > 0 {
			b.WriteByte('\n')
		}
		fmt.Fprintf(&b, "[hooks.state.%s]\n", strconv.Quote(entry.Key))
		fmt.Fprintf(&b, "trusted_hash = %q\n", entry.Hash)
	}
	b.WriteString(legacyCodexTrustEnd)
	b.WriteByte('\n')
	return b.String()
}
