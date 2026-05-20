package hooks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

var codexEvents = []codexEntry{
	{Event: "SessionStart", Action: "starting"},
	{Event: "UserPromptSubmit", Action: "working"},
	{Event: "PreToolUse", Action: "tool_start"},
	{Event: "PostToolUse", Action: "tool_end"},
	{Event: "Stop", Action: "done"},
}

type codexEntry struct {
	Event  string
	Action string
}

// CodexInstaller manages the Codex hook surface. Writes the script to
// ~/.codex/hooks/party-cli-state.sh and merges tagged entries into
// ~/.codex/hooks.json. It intentionally does not mutate config.toml.
type CodexInstaller struct {
	Home string
}

// NewCodexInstaller resolves $CODEX_HOME / $HOME. Pass an explicit home
// for tests; pass "" to honour $CODEX_HOME / $HOME.
func NewCodexInstaller(home string) *CodexInstaller {
	if home == "" {
		home = os.Getenv("CODEX_HOME")
	}
	if home == "" {
		if h := os.Getenv("HOME"); h != "" {
			home = filepath.Join(h, ".codex")
		}
	}
	return &CodexInstaller{Home: home}
}

// Name implements Installer.
func (c *CodexInstaller) Name() string { return "codex" }

func (c *CodexInstaller) scriptPath() string {
	return filepath.Join(c.Home, "hooks", "party-cli-state.sh")
}

func (c *CodexInstaller) hooksPath() string {
	return filepath.Join(c.Home, "hooks.json")
}

func (c *CodexInstaller) backupPath() string {
	return c.hooksPath() + ".party-cli.bak"
}

func (c *CodexInstaller) configPath() string {
	return filepath.Join(c.Home, "config.toml")
}

// Install implements Installer.
func (c *CodexInstaller) Install() error {
	if c.Home == "" {
		return fmt.Errorf("codex home not resolved (set $CODEX_HOME or $HOME)")
	}
	body := []byte(RenderScript("codex"))
	if err := c.writeScript(body); err != nil {
		return err
	}
	return c.mergeHooks(hashBytes(body))
}

// Uninstall implements Installer. Removes tagged entries from hooks.json
// and deletes the installed script. Untagged user hooks and config.toml
// are left alone.
func (c *CodexInstaller) Uninstall() error {
	if c.Home == "" {
		return fmt.Errorf("codex home not resolved")
	}
	if err := c.removeFromHooks(); err != nil {
		return err
	}
	if err := os.Remove(c.scriptPath()); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove codex script: %w", err)
	}
	return nil
}

// Status implements Installer.
func (c *CodexInstaller) Status() Report {
	if c.Home == "" {
		return Report{Agent: "codex", Status: StatusNotInstalled, Detail: "home dir not resolved"}
	}
	doc, err := c.loadHooks()
	if err != nil {
		return Report{Agent: "codex", Status: StatusOutdated, Detail: fmt.Sprintf("hooks.json unreadable: %v", err)}
	}
	entries := c.taggedEntries(doc)
	tagged := len(entries)

	scriptBytes, scriptErr := os.ReadFile(c.scriptPath())
	scriptExists := scriptErr == nil
	if !scriptExists && tagged == 0 {
		return Report{Agent: "codex", Status: StatusNotInstalled}
	}

	for _, entry := range entries {
		if h, _ := entry["trusted_hash"].(string); h == "" {
			return Report{Agent: "codex", Status: StatusUntrusted, Detail: "trusted_hash missing"}
		}
	}

	if scriptExists && tagged > 0 {
		actualHash := hashBytes(scriptBytes)
		for _, entry := range entries {
			if h, _ := entry["trusted_hash"].(string); h != actualHash {
				return Report{Agent: "codex", Status: StatusModified, Detail: "script hash differs from trusted_hash"}
			}
		}
	}

	scriptOK := scriptExists && string(scriptBytes) == RenderScript("codex")
	pluginHooksOK := c.pluginHooksEnabled()
	entriesOK := c.codexEntriesCurrent(entries)
	versionOK := codexVersionOK(doc)
	if scriptOK && entriesOK && versionOK && pluginHooksOK {
		return Report{Agent: "codex", Status: StatusCurrent}
	}
	return Report{
		Agent:  "codex",
		Status: StatusOutdated,
		Detail: fmt.Sprintf("script_ok=%v tagged_entries=%d/%d version_ok=%v plugin_hooks=%v", scriptOK, tagged, len(codexEvents), versionOK, pluginHooksOK),
	}
}

func (c *CodexInstaller) writeScript(body []byte) error {
	dir := filepath.Join(c.Home, "hooks")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir codex hooks: %w", err)
	}
	tmp := c.scriptPath() + ".tmp"
	if err := os.WriteFile(tmp, body, 0o755); err != nil {
		return fmt.Errorf("write codex script: %w", err)
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return fmt.Errorf("chmod codex script: %w", err)
	}
	if err := os.Rename(tmp, c.scriptPath()); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename codex script: %w", err)
	}
	return nil
}

func (c *CodexInstaller) loadHooks() (map[string]interface{}, error) {
	data, err := os.ReadFile(c.hooksPath())
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]interface{}{
				"version": float64(1),
				"hooks":   []interface{}{},
			}, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return map[string]interface{}{
			"version": float64(1),
			"hooks":   []interface{}{},
		}, nil
	}
	var doc map[string]interface{}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse hooks.json: %w", err)
	}
	if doc == nil {
		doc = map[string]interface{}{}
	}
	if _, ok := doc["version"]; !ok {
		doc["version"] = float64(1)
	}
	rawHooks, ok := doc["hooks"]
	if !ok || rawHooks == nil {
		doc["hooks"] = []interface{}{}
		return doc, nil
	}
	if _, ok := rawHooks.([]interface{}); !ok {
		return nil, fmt.Errorf("hooks.json hooks must be an array")
	}
	return doc, nil
}

func (c *CodexInstaller) mergeHooks(trustedHash string) error {
	doc, err := c.loadHooks()
	if err != nil {
		return err
	}
	if err := c.backupIfNeeded(); err != nil {
		return err
	}
	doc["version"] = float64(1)
	rawHooks, _ := doc["hooks"].([]interface{})
	filtered := dropTaggedEntries(rawHooks)
	for _, event := range codexEvents {
		filtered = append(filtered, c.buildEntry(event, trustedHash))
	}
	doc["hooks"] = filtered
	return c.writeHooks(doc)
}

func (c *CodexInstaller) backupIfNeeded() error {
	if _, err := os.Stat(c.hooksPath()); err != nil {
		return nil
	}
	if _, err := os.Stat(c.backupPath()); err == nil {
		return nil
	}
	data, err := os.ReadFile(c.hooksPath())
	if err != nil {
		return err
	}
	return os.WriteFile(c.backupPath(), data, 0o644)
}

func (c *CodexInstaller) removeFromHooks() error {
	data, err := os.ReadFile(c.hooksPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var doc map[string]interface{}
	if err := json.Unmarshal(data, &doc); err != nil {
		return fmt.Errorf("parse hooks.json: %w", err)
	}
	rawHooks, ok := doc["hooks"].([]interface{})
	if !ok {
		return nil
	}
	doc["hooks"] = dropTaggedEntries(rawHooks)
	if _, ok := doc["version"]; !ok {
		doc["version"] = float64(1)
	}
	return c.writeHooks(doc)
}

func (c *CodexInstaller) writeHooks(doc map[string]interface{}) error {
	updated, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return fmt.Errorf("encode hooks.json: %w", err)
	}
	updated = append(updated, '\n')
	if existing, err := os.ReadFile(c.hooksPath()); err == nil && string(existing) == string(updated) {
		return nil
	}
	return atomicWrite(c.hooksPath(), updated)
}

func (c *CodexInstaller) buildEntry(e codexEntry, trustedHash string) map[string]interface{} {
	return map[string]interface{}{
		"_party_cli":   AssetTag,
		"event":        e.Event,
		"command":      []interface{}{c.scriptPath(), e.Action},
		"stdin":        "passthrough",
		"trusted_hash": trustedHash,
	}
}

func (c *CodexInstaller) taggedEntries(doc map[string]interface{}) []map[string]interface{} {
	rawHooks, _ := doc["hooks"].([]interface{})
	out := make([]map[string]interface{}, 0, len(rawHooks))
	for _, raw := range rawHooks {
		obj, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		if tag, _ := obj["_party_cli"].(string); tag == AssetTag {
			out = append(out, obj)
		}
	}
	return out
}

func (c *CodexInstaller) codexEntriesCurrent(entries []map[string]interface{}) bool {
	if len(entries) != len(codexEvents) {
		return false
	}
	want := make(map[string]string, len(codexEvents))
	for _, e := range codexEvents {
		want[e.Event] = e.Action
	}
	for _, entry := range entries {
		event, _ := entry["event"].(string)
		action, ok := want[event]
		if !ok {
			return false
		}
		if stdin, _ := entry["stdin"].(string); stdin != "passthrough" {
			return false
		}
		command, ok := entry["command"].([]interface{})
		if !ok || len(command) != 2 {
			return false
		}
		if script, _ := command[0].(string); script != c.scriptPath() {
			return false
		}
		if gotAction, _ := command[1].(string); gotAction != action {
			return false
		}
		delete(want, event)
	}
	return len(want) == 0
}

func (c *CodexInstaller) pluginHooksEnabled() bool {
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		return false
	}
	var cfg struct {
		Features struct {
			PluginHooks bool `toml:"plugin_hooks"`
		} `toml:"features"`
	}
	if _, err := toml.Decode(string(data), &cfg); err != nil {
		return false
	}
	return cfg.Features.PluginHooks
}

func codexVersionOK(doc map[string]interface{}) bool {
	switch v := doc["version"].(type) {
	case float64:
		return v == 1
	case int:
		return v == 1
	case json.Number:
		i, err := v.Int64()
		return err == nil && i == 1
	default:
		return false
	}
}

func hashBytes(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
