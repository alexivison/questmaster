package hooks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// claudeEvents maps each Claude hook event we install to the action arg
// passed to `party-cli hook claude <action>`. The mapping reflects
// PLAN.md "Claude installer details" (lines 222–243).
//
// SubagentStop is installed because we want the activity-only update
// even when the parent state suppression rule fires. The subagent rule
// in cmd/hook.go drops the state mutation but still updates Activity.
var claudeEvents = []claudeEntry{
	{Event: "SessionStart", Action: "starting"},
	{Event: "UserPromptSubmit", Action: "working"},
	{Event: "PreToolUse", Action: "tool_start"},
	{Event: "PostToolUse", Action: "tool_end"},
	{Event: "Stop", Action: "done"},
	{Event: "SubagentStop", Action: "subagent_stop"},
	{Event: "Notification", Action: "blocked"},
	{Event: "SessionEnd", Action: "stopped"},
}

type claudeEntry struct {
	Event  string
	Action string
}

// ClaudeInstaller manages the Claude Code hook surface. Writes the
// script to ~/.claude/hooks/party-cli-state.sh and merges tagged hook
// entries into ~/.claude/settings.local.json (overlay file — never the
// checked-in settings.json).
type ClaudeInstaller struct {
	// Home is the resolved Claude config directory (~/.claude or
	// $CLAUDE_CONFIG_DIR). Override only in tests.
	Home string
}

// NewClaudeInstaller resolves the Claude config directory. Pass an
// explicit home for tests; pass "" to honour $CLAUDE_CONFIG_DIR / $HOME.
func NewClaudeInstaller(home string) *ClaudeInstaller {
	if home == "" {
		home = os.Getenv("CLAUDE_CONFIG_DIR")
	}
	if home == "" {
		if h := os.Getenv("HOME"); h != "" {
			home = filepath.Join(h, ".claude")
		}
	}
	return &ClaudeInstaller{Home: home}
}

// Name implements Installer.
func (c *ClaudeInstaller) Name() string { return "claude" }

func (c *ClaudeInstaller) scriptPath() string {
	return filepath.Join(c.Home, "hooks", "party-cli-state.sh")
}

func (c *ClaudeInstaller) settingsPath() string {
	return filepath.Join(c.Home, "settings.local.json")
}

func (c *ClaudeInstaller) backupPath() string {
	return c.settingsPath() + ".party-cli.bak"
}

// Install implements Installer.
func (c *ClaudeInstaller) Install() error {
	if c.Home == "" {
		return errors.New("claude home not resolved (set $CLAUDE_CONFIG_DIR or $HOME)")
	}
	if err := c.writeScript(); err != nil {
		return err
	}
	return c.mergeSettings()
}

// Uninstall implements Installer. Removes tagged entries from
// settings.local.json and deletes the installed script. Untagged user
// hooks are left alone.
func (c *ClaudeInstaller) Uninstall() error {
	if c.Home == "" {
		return errors.New("claude home not resolved")
	}
	if err := c.removeFromSettings(); err != nil {
		return err
	}
	scriptPath := c.scriptPath()
	if err := os.Remove(scriptPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove claude script: %w", err)
	}
	return nil
}

// Status implements Installer.
func (c *ClaudeInstaller) Status() Report {
	if c.Home == "" {
		return Report{Agent: "claude", Status: StatusNotInstalled, Detail: "home dir not resolved"}
	}
	scriptPath := c.scriptPath()
	scriptOK := false
	if data, err := os.ReadFile(scriptPath); err == nil {
		scriptOK = string(data) == RenderScript("claude")
	}
	settings, err := c.loadSettings()
	if err != nil {
		return Report{Agent: "claude", Status: StatusOutdated, Detail: fmt.Sprintf("settings unreadable: %v", err)}
	}
	tagged := c.countTagged(settings)
	want := len(claudeEvents)
	switch {
	case !scriptOK && tagged == 0:
		return Report{Agent: "claude", Status: StatusNotInstalled}
	case scriptOK && tagged == want:
		return Report{Agent: "claude", Status: StatusCurrent}
	default:
		return Report{
			Agent:  "claude",
			Status: StatusOutdated,
			Detail: fmt.Sprintf("script_ok=%v tagged_entries=%d/%d", scriptOK, tagged, want),
		}
	}
}

func (c *ClaudeInstaller) writeScript() error {
	dir := filepath.Join(c.Home, "hooks")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir claude hooks: %w", err)
	}
	body := []byte(RenderScript("claude"))
	tmp := c.scriptPath() + ".tmp"
	if err := os.WriteFile(tmp, body, 0o755); err != nil {
		return fmt.Errorf("write claude script: %w", err)
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return fmt.Errorf("chmod claude script: %w", err)
	}
	if err := os.Rename(tmp, c.scriptPath()); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename claude script: %w", err)
	}
	return nil
}

func (c *ClaudeInstaller) loadSettings() (map[string]interface{}, error) {
	data, err := os.ReadFile(c.settingsPath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return map[string]interface{}{}, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return map[string]interface{}{}, nil
	}
	var settings map[string]interface{}
	if err := json.Unmarshal(data, &settings); err != nil {
		return nil, fmt.Errorf("parse settings.local.json: %w", err)
	}
	if settings == nil {
		settings = map[string]interface{}{}
	}
	return settings, nil
}

func (c *ClaudeInstaller) mergeSettings() error {
	settings, err := c.loadSettings()
	if err != nil {
		return err
	}
	original, _ := json.Marshal(settings)
	if err := c.backupIfNeeded(); err != nil {
		return err
	}
	c.mergeOurEntries(settings)
	updated, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return fmt.Errorf("encode settings: %w", err)
	}
	updated = append(updated, '\n')
	// Idempotency short-circuit: if a re-install produces the same byte
	// payload (modulo trailing newline) skip the write so file mtime
	// stays stable across repeated installs.
	if existing, err := os.ReadFile(c.settingsPath()); err == nil {
		if bytesEqualWithOptionalNewline(existing, updated) {
			_ = original // silence unused
			return nil
		}
	}
	return atomicWrite(c.settingsPath(), updated)
}

func (c *ClaudeInstaller) backupIfNeeded() error {
	src := c.settingsPath()
	if _, err := os.Stat(src); err != nil {
		// Nothing to back up.
		return nil
	}
	if _, err := os.Stat(c.backupPath()); err == nil {
		return nil
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(c.backupPath(), data, 0o644)
}

// mergeOurEntries mutates `settings["hooks"]` to contain exactly one
// tagged entry per (event, action) pair we own. Existing tagged entries
// are dropped and rewritten; user-managed (untagged) entries are
// preserved unchanged.
func (c *ClaudeInstaller) mergeOurEntries(settings map[string]interface{}) {
	hooks, _ := settings["hooks"].(map[string]interface{})
	if hooks == nil {
		hooks = map[string]interface{}{}
		settings["hooks"] = hooks
	}
	for _, e := range claudeEvents {
		existing, _ := hooks[e.Event].([]interface{})
		filtered := dropTaggedEntries(existing)
		filtered = append(filtered, c.buildEntry(e))
		hooks[e.Event] = filtered
	}
}

// removeFromSettings drops only tagged entries and prunes empty event
// arrays. Returns nil if settings.local.json is missing.
func (c *ClaudeInstaller) removeFromSettings() error {
	data, err := os.ReadFile(c.settingsPath())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	var settings map[string]interface{}
	if err := json.Unmarshal(data, &settings); err != nil {
		return fmt.Errorf("parse settings.local.json: %w", err)
	}
	hooks, _ := settings["hooks"].(map[string]interface{})
	if hooks == nil {
		return nil
	}
	for ev, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		filtered := dropTaggedEntries(arr)
		if len(filtered) == 0 {
			delete(hooks, ev)
		} else {
			hooks[ev] = filtered
		}
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
	updated, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	updated = append(updated, '\n')
	return atomicWrite(c.settingsPath(), updated)
}

func (c *ClaudeInstaller) buildEntry(e claudeEntry) map[string]interface{} {
	scriptCmd := fmt.Sprintf("%s %s", c.scriptPath(), e.Action)
	// matcher is required by Claude Code — entries without it are silently
	// ignored. Empty string matches all tools (and is harmless for non-tool
	// events like SessionStart / Stop).
	return map[string]interface{}{
		"matcher":    "",
		"_party_cli": AssetTag,
		"hooks": []interface{}{
			map[string]interface{}{
				"type":    "command",
				"command": scriptCmd,
				"timeout": 5,
			},
		},
	}
}

func (c *ClaudeInstaller) countTagged(settings map[string]interface{}) int {
	hooks, _ := settings["hooks"].(map[string]interface{})
	count := 0
	for _, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		for _, item := range arr {
			obj, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			if tag, _ := obj["_party_cli"].(string); tag == AssetTag {
				count++
			}
		}
	}
	return count
}

// dropTaggedEntries keeps entries whose `_party_cli` tag does not equal
// AssetTag. The shape is opaque so unknown user keys are preserved.
func dropTaggedEntries(arr []interface{}) []interface{} {
	out := make([]interface{}, 0, len(arr))
	for _, item := range arr {
		obj, ok := item.(map[string]interface{})
		if !ok {
			out = append(out, item)
			continue
		}
		if tag, _ := obj["_party_cli"].(string); tag == AssetTag {
			continue
		}
		out = append(out, item)
	}
	return out
}

// atomicWrite writes bytes via a tmp file + rename in the same dir as
// the target.
func atomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return err
	}
	return nil
}

func bytesEqualWithOptionalNewline(a, b []byte) bool {
	if len(a) == len(b) {
		return string(a) == string(b)
	}
	return false
}

// ScriptHash exposes a sha256 of the rendered script for the named
// agent. The Codex installer uses this in PR-B for the `trusted_hash`
// field; surfaced here so PR-A tests can exercise the helper too.
func ScriptHash(agent string) string {
	sum := sha256.Sum256([]byte(RenderScript(agent)))
	return hex.EncodeToString(sum[:])
}

// AgentList returns the canonical agent identifiers (sorted) — exported
// so cmd/hooks.go can render the human-readable status output without
// having to instantiate a Manager.
func AgentList() []string {
	out := []string{"claude", "codex", "pi"}
	sort.Strings(out)
	return out
}
