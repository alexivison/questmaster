package hooks

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/BurntSushi/toml"
)

var codexEvents = []codexEntry{
	{Event: "SessionStart", HookKey: "session_start", Action: "starting"},
	{Event: "UserPromptSubmit", HookKey: "user_prompt_submit", Action: "working"},
	{Event: "PreToolUse", HookKey: "pre_tool_use", Action: "tool_start"},
	{Event: "PostToolUse", HookKey: "post_tool_use", Action: "tool_end"},
	{Event: "Stop", HookKey: "stop", Action: "done"},
	{Event: "PermissionRequest", HookKey: "permission_request", Action: "permission"},
}

type codexEntry struct {
	Event   string
	HookKey string
	Action  string
}

const (
	codexHookTimeoutSec = 5
	codexTrustBegin     = "# BEGIN party-cli codex hook trust"
	codexTrustEnd       = "# END party-cli codex hook trust"
)

// CodexInstaller manages the Codex hook surface. Writes the script to
// ~/.codex/hooks/party-cli-state.sh, merges tagged entries into
// ~/.codex/hooks.json, and records Codex's required trusted_hash state in
// ~/.codex/config.toml.
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
	if err := c.mergeHooks(); err != nil {
		return err
	}
	return c.mergeTrustState()
}

// Uninstall implements Installer. Removes tagged entries from hooks.json,
// removes party-cli's managed trust block from config.toml, and deletes the
// installed script. Untagged user hooks and config keys are left alone.
func (c *CodexInstaller) Uninstall() error {
	if c.Home == "" {
		return fmt.Errorf("codex home not resolved")
	}
	if err := c.removeFromHooks(); err != nil {
		return err
	}
	if err := c.removeTrustState(); err != nil {
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

	scriptOK := scriptExists && string(scriptBytes) == RenderScript("codex")
	entriesOK := c.codexEntriesCurrent(entries)
	hooksFeatureOK := c.hooksFeatureEnabled()
	trustOK, trustModified, trustDetail := c.trustStateCurrent()
	switch {
	case scriptExists && !scriptOK:
		return Report{Agent: "codex", Status: StatusModified, Detail: "script body differs from rendered hook"}
	case scriptOK && entriesOK && hooksFeatureOK && trustOK:
		return Report{Agent: "codex", Status: StatusCurrent}
	case entriesOK && !trustOK && trustModified:
		return Report{Agent: "codex", Status: StatusModified, Detail: trustDetail}
	case entriesOK && !trustOK:
		return Report{Agent: "codex", Status: StatusUntrusted, Detail: trustDetail}
	default:
		return Report{
			Agent:  "codex",
			Status: StatusOutdated,
			Detail: fmt.Sprintf("script_ok=%v tagged_entries=%d/%d entries_ok=%v hooks_feature=%v trust_ok=%v", scriptOK, tagged, len(codexEvents), entriesOK, hooksFeatureOK, trustOK),
		}
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
				"hooks": map[string]interface{}{},
			}, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return map[string]interface{}{
			"hooks": map[string]interface{}{},
		}, nil
	}
	var doc map[string]interface{}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("parse hooks.json: %w", err)
	}
	if doc == nil {
		doc = map[string]interface{}{}
	}
	rawHooks, ok := doc["hooks"]
	if !ok || rawHooks == nil {
		doc["hooks"] = map[string]interface{}{}
		return doc, nil
	}
	switch rawHooks.(type) {
	case map[string]interface{}:
	case []interface{}:
		// Migrate the invalid Phase 1 PR-B shape to Codex v0.130's event map.
		doc["hooks"] = map[string]interface{}{}
	default:
		return nil, fmt.Errorf("hooks.json hooks must be an object")
	}
	return doc, nil
}

func (c *CodexInstaller) mergeHooks() error {
	doc, err := c.loadHooks()
	if err != nil {
		return err
	}
	if err := c.backupIfNeeded(); err != nil {
		return err
	}
	hooks, _ := doc["hooks"].(map[string]interface{})
	if hooks == nil {
		hooks = map[string]interface{}{}
		doc["hooks"] = hooks
	}
	for _, event := range codexEvents {
		existing, _ := hooks[event.Event].([]interface{})
		filtered := dropTaggedEntries(existing)
		filtered = append(filtered, c.buildEntry(event))
		hooks[event.Event] = filtered
	}
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
	hooks, ok := doc["hooks"].(map[string]interface{})
	if !ok {
		return nil
	}
	for event, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		filtered := dropTaggedEntries(arr)
		if len(filtered) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = filtered
		}
	}
	if len(hooks) == 0 {
		delete(doc, "hooks")
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

func (c *CodexInstaller) buildEntry(e codexEntry) map[string]interface{} {
	return map[string]interface{}{
		"_party_cli": AssetTag,
		"hooks": []interface{}{
			map[string]interface{}{
				"type":    "command",
				"command": c.commandString(e),
				"timeout": float64(codexHookTimeoutSec),
			},
		},
	}
}

func (c *CodexInstaller) taggedEntries(doc map[string]interface{}) []map[string]interface{} {
	hooks, _ := doc["hooks"].(map[string]interface{})
	out := make([]map[string]interface{}, 0, len(codexEvents))
	for _, raw := range hooks {
		arr, ok := raw.([]interface{})
		if !ok {
			continue
		}
		for _, rawEntry := range arr {
			obj, ok := rawEntry.(map[string]interface{})
			if !ok {
				continue
			}
			if tag, _ := obj["_party_cli"].(string); tag == AssetTag {
				out = append(out, obj)
			}
		}
	}
	return out
}

func (c *CodexInstaller) codexEntriesCurrent(entries []map[string]interface{}) bool {
	if len(entries) != len(codexEvents) {
		return false
	}
	doc, err := c.loadHooks()
	if err != nil {
		return false
	}
	hooks, _ := doc["hooks"].(map[string]interface{})
	for _, e := range codexEvents {
		if !c.eventEntryCurrent(hooks[e.Event], e) {
			return false
		}
	}
	return true
}

func (c *CodexInstaller) eventEntryCurrent(raw interface{}, e codexEntry) bool {
	arr, ok := raw.([]interface{})
	if !ok {
		return false
	}
	found := 0
	for _, item := range arr {
		entry, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if tag, _ := entry["_party_cli"].(string); tag != AssetTag {
			continue
		}
		found++
		hooks, ok := entry["hooks"].([]interface{})
		if !ok || len(hooks) != 1 {
			return false
		}
		handler, ok := hooks[0].(map[string]interface{})
		if !ok {
			return false
		}
		if typ, _ := handler["type"].(string); typ != "command" {
			return false
		}
		if command, _ := handler["command"].(string); command != c.commandString(e) {
			return false
		}
		if !numericEqual(handler["timeout"], codexHookTimeoutSec) {
			return false
		}
	}
	return found == 1
}

func (c *CodexInstaller) hooksFeatureEnabled() bool {
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		return true
	}
	var cfg struct {
		Features struct {
			Hooks      *bool `toml:"hooks"`
			CodexHooks *bool `toml:"codex_hooks"`
		} `toml:"features"`
	}
	if _, err := toml.Decode(string(data), &cfg); err != nil {
		return false
	}
	if cfg.Features.Hooks != nil {
		return *cfg.Features.Hooks
	}
	if cfg.Features.CodexHooks != nil {
		return *cfg.Features.CodexHooks
	}
	return true
}

func (c *CodexInstaller) mergeTrustState() error {
	trust, err := c.trustEntries()
	if err != nil {
		return err
	}
	body := ""
	if data, err := os.ReadFile(c.configPath()); err == nil {
		body = string(data)
	} else if !os.IsNotExist(err) {
		return err
	}
	body = strings.TrimRight(stripCodexTrustBlock(body), "\n")
	if body != "" {
		body += "\n\n"
	}
	body += c.renderTrustBlock(trust)
	return atomicWrite(c.configPath(), []byte(body))
}

func (c *CodexInstaller) removeTrustState() error {
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	updated := stripCodexTrustBlock(string(data))
	if updated == string(data) {
		return nil
	}
	return atomicWrite(c.configPath(), []byte(updated))
}

func (c *CodexInstaller) renderTrustBlock(entries []codexTrustEntry) string {
	var b strings.Builder
	b.WriteString(codexTrustBegin)
	b.WriteByte('\n')
	for i, entry := range entries {
		if i > 0 {
			b.WriteByte('\n')
		}
		fmt.Fprintf(&b, "[hooks.state.%s]\n", strconv.Quote(entry.Key))
		fmt.Fprintf(&b, "trusted_hash = %q\n", entry.Hash)
	}
	b.WriteString(codexTrustEnd)
	b.WriteByte('\n')
	return b.String()
}

func stripCodexTrustBlock(body string) string {
	for {
		start := strings.Index(body, codexTrustBegin)
		if start == -1 {
			return body
		}
		relEnd := strings.Index(body[start:], codexTrustEnd)
		if relEnd == -1 {
			return strings.TrimRight(body[:start], "\n")
		}
		end := start + relEnd + len(codexTrustEnd)
		for end < len(body) && (body[end] == '\n' || body[end] == '\r') {
			end++
		}
		removeStart := start
		if removeStart >= 2 && body[removeStart-1] == '\n' && body[removeStart-2] == '\n' {
			removeStart--
		}
		body = body[:removeStart] + body[end:]
	}
}

func (c *CodexInstaller) trustStateCurrent() (ok bool, modified bool, detail string) {
	trust, err := c.trustEntries()
	if err != nil {
		return false, false, err.Error()
	}
	data, err := os.ReadFile(c.configPath())
	if err != nil {
		return false, false, "config.toml missing trusted hook state"
	}
	var cfg struct {
		Hooks struct {
			State map[string]struct {
				TrustedHash string `toml:"trusted_hash"`
			} `toml:"state"`
		} `toml:"hooks"`
	}
	if _, err := toml.Decode(string(data), &cfg); err != nil {
		return false, false, fmt.Sprintf("parse config.toml: %v", err)
	}
	for _, entry := range trust {
		state, exists := cfg.Hooks.State[entry.Key]
		if !exists || state.TrustedHash == "" {
			return false, false, "trusted hook state missing"
		}
		if state.TrustedHash != entry.Hash {
			return false, true, "trusted hook hash differs from current hook identity"
		}
	}
	return true, false, ""
}

type codexTrustEntry struct {
	Key  string
	Hash string
}

func (c *CodexInstaller) trustEntries() ([]codexTrustEntry, error) {
	sourcePath, err := c.codexSourcePath()
	if err != nil {
		return nil, err
	}
	out := make([]codexTrustEntry, 0, len(codexEvents))
	for _, event := range codexEvents {
		out = append(out, codexTrustEntry{
			Key:  fmt.Sprintf("%s:%s:0:0", sourcePath, event.HookKey),
			Hash: c.commandHookHash(event),
		})
	}
	return out, nil
}

func (c *CodexInstaller) codexSourcePath() (string, error) {
	path := c.hooksPath()
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved, nil
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	return abs, nil
}

func (c *CodexInstaller) commandString(e codexEntry) string {
	return fmt.Sprintf("%s %s", c.scriptPath(), e.Action)
}

func (c *CodexInstaller) commandHookHash(e codexEntry) string {
	identity := map[string]interface{}{
		"event_name": e.HookKey,
		"hooks": []interface{}{
			map[string]interface{}{
				"async":   false,
				"command": c.commandString(e),
				"timeout": codexHookTimeoutSec,
				"type":    "command",
			},
		},
	}
	serialized, _ := json.Marshal(identity)
	sum := sha256.Sum256(serialized)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func numericEqual(value interface{}, want int) bool {
	switch got := value.(type) {
	case float64:
		return got == float64(want)
	case int:
		return got == want
	case json.Number:
		i, err := got.Int64()
		return err == nil && i == int64(want)
	default:
		return false
	}
}
