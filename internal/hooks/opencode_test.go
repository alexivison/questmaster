package hooks

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	qmagent "github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

func newTestOpenCodeInstaller(t *testing.T) *OpenCodeInstaller {
	t.Helper()
	return &OpenCodeInstaller{ConfigDir: t.TempDir()}
}

func TestOpenCodeInstallerDefaultsToQuestmasterStateRoot(t *testing.T) {
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("OPENCODE_CONFIG_DIR", filepath.Join(t.TempDir(), "user-opencode"))

	o := NewOpenCodeInstaller("")
	if got, want := o.ConfigDir, state.OpenCodeConfigDir(root); got != want {
		t.Fatalf("ConfigDir = %q, want %q", got, want)
	}
}

func TestOpenCodeInstallIsIdempotentAndCurrent(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first := readOpenCodeManagedFiles(t, o)
	if got := o.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
	}

	if err := o.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second := readOpenCodeManagedFiles(t, o)
	if len(first) != len(second) {
		t.Fatalf("managed file count changed: %d -> %d", len(first), len(second))
	}
	for path, body := range first {
		if second[path] != body {
			t.Fatalf("re-install changed %s", path)
		}
	}
}

func TestOpenCodeInstallPopulatesRoleAgents(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}

	for _, name := range []string{qmagent.OpenCodeMasterAgentName, qmagent.OpenCodeWorkerAgentName} {
		data, err := os.ReadFile(o.agentPath(name))
		if err != nil {
			t.Fatalf("read agent %s: %v", name, err)
		}
		body := string(data)
		if !strings.Contains(body, "mode: primary") {
			t.Fatalf("%s missing primary mode frontmatter", name)
		}
		if !strings.Contains(body, "permission:\n  \"*\": allow\n") ||
			!strings.Contains(body, "  external_directory:\n    \"*\": allow\n") ||
			!strings.Contains(body, "  doom_loop: allow\n") {
			t.Fatalf("%s missing OpenCode permission allow frontmatter", name)
		}
		if !strings.Contains(body, "The questmaster CLI is available") &&
			!strings.Contains(body, "This is a master session") &&
			!strings.Contains(body, "This is a worker session") {
			t.Fatalf("%s missing Questmaster role prompt", name)
		}
	}
}

func TestOpenCodeDryRunDoesNotWriteFiles(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	var log strings.Builder
	if err := o.InstallWithOptions(InstallOptions{DryRun: true, Log: &log}); err != nil {
		t.Fatalf("dry-run install: %v", err)
	}
	if _, err := os.Stat(o.pluginPath()); !os.IsNotExist(err) {
		t.Fatalf("dry-run wrote plugin file (err=%v)", err)
	}
	if !strings.Contains(log.String(), "would write OpenCode plugin") {
		t.Fatalf("dry-run log missing plugin write: %q", log.String())
	}
}

func TestOpenCodeUninstallPreservesUserFiles(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	userPlugin := filepath.Join(o.ConfigDir, "plugins", "user-plugin.js")
	userAgent := filepath.Join(o.ConfigDir, "agents", "user-agent.md")
	if err := os.WriteFile(userPlugin, []byte("export const User = async () => ({})\n"), 0o644); err != nil {
		t.Fatalf("write user plugin: %v", err)
	}
	if err := os.WriteFile(userAgent, []byte("---\nmode: primary\n---\nuser\n"), 0o644); err != nil {
		t.Fatalf("write user agent: %v", err)
	}

	if err := o.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	for _, file := range o.managedFiles() {
		if _, err := os.Stat(file.Path); !os.IsNotExist(err) {
			t.Fatalf("managed file still present %s (err=%v)", file.Path, err)
		}
	}
	for _, file := range []string{userPlugin, userAgent} {
		if _, err := os.Stat(file); err != nil {
			t.Fatalf("user file was not preserved %s: %v", file, err)
		}
	}
}

func TestOpenCodeStatusModifiedOnManagedDiff(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := os.WriteFile(o.pluginPath(), []byte("// hand-edited\n"), 0o644); err != nil {
		t.Fatalf("tamper plugin: %v", err)
	}
	if got := o.Status(); got.Status != StatusModified {
		t.Fatalf("status: want %s, got %+v", StatusModified, got)
	}
}

func TestOpenCodePluginEmbedsVersionMarkerAndSingleExport(t *testing.T) {
	want := `const SIDECAR_VERSION = "` + openCodeSidecarVersion + `";`
	if !strings.Contains(openCodePluginSource, want) {
		t.Fatalf("embedded OpenCode plugin missing version marker %q", openCodeSidecarVersion)
	}
	for _, want := range []string{`accessSync(bin, constants.X_OK)`, `return "questmaster"`} {
		if !strings.Contains(openCodePluginSource, want) {
			t.Fatalf("embedded OpenCode plugin missing executable QUESTMASTER_BIN fallback %q", want)
		}
	}

	exportRE := regexp.MustCompile(`(?m)^\s*export\s+const\s+([A-Za-z0-9_]+)\b`)
	matches := exportRE.FindAllStringSubmatch(openCodePluginSource, -1)
	exports := make([]string, 0, len(matches))
	for _, match := range matches {
		exports = append(exports, match[1])
	}
	if len(exports) != 1 || exports[0] != "QuestmasterOpenCode" {
		t.Fatalf("plugin exports = %v, want [QuestmasterOpenCode]", exports)
	}
}

func TestOpenCodePluginForwardsToolExecutionHooks(t *testing.T) {
	t.Parallel()
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	dir := t.TempDir()
	pluginPath := filepath.Join(dir, "plugin.mjs")
	if err := os.WriteFile(pluginPath, []byte(openCodePluginSource), 0o600); err != nil {
		t.Fatalf("write plugin: %v", err)
	}
	stubPath := filepath.Join(dir, "questmaster")
	stub := "#!/usr/bin/env node\nimport { writeFileSync } from 'node:fs';\nlet input = '';\nfor await (const chunk of process.stdin) input += chunk;\nconst payload = JSON.parse(input);\nwriteFileSync(`${process.env.QM_CAPTURE}/${payload.event.type}.json`, input);\n"
	if err := os.WriteFile(stubPath, []byte(stub), 0o700); err != nil {
		t.Fatalf("write qm stub: %v", err)
	}
	captureDir := filepath.Join(dir, "capture")
	if err := os.Mkdir(captureDir, 0o700); err != nil {
		t.Fatalf("create capture dir: %v", err)
	}
	script := `import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const { QuestmasterOpenCode } = await import(pathToFileURL(process.env.QM_PLUGIN));
const hooks = await QuestmasterOpenCode();
const input = { tool: "bash", sessionID: "ses-1", callID: "call-1" };
const args = { command: "go test ./..." };
await hooks["tool.execute.before"](input, { args });
await hooks["tool.execute.after"]({ ...input, args }, { title: "bash", output: "", metadata: {} });
const wait = async (name) => {
  const path = process.env.QM_CAPTURE + "/" + name + ".json";
  const until = Date.now() + 3000;
  while (!existsSync(path) && Date.now() < until) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.ok(existsSync(path), name + " hook was not emitted");
  return JSON.parse(readFileSync(path, "utf8"));
};
const before = await wait("tool.execute.before");
const after = await wait("tool.execute.after");
assert.deepEqual(before.event.properties, { ...input, args });
assert.deepEqual(after.event.properties, { ...input, args });
`
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, node, "--input-type=module", "-e", script)
	cmd.Env = append(os.Environ(),
		"QUESTMASTER_SESSION=qm-plugin-test",
		"QUESTMASTER_BIN="+stubPath,
		"QM_CAPTURE="+captureDir,
		"QM_PLUGIN="+pluginPath,
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("OpenCode plugin hook check: %v\n%s", err, out)
	}
}

func TestOpenCodeRegisteredInManager(t *testing.T) {
	m := NewManager()
	if _, err := m.Resolve("opencode"); err != nil {
		t.Fatalf("manager missing opencode installer: %v", err)
	}
}

func readOpenCodeManagedFiles(t *testing.T, o *OpenCodeInstaller) map[string]string {
	t.Helper()
	out := map[string]string{}
	for _, file := range o.managedFiles() {
		data, err := os.ReadFile(file.Path)
		if err != nil {
			t.Fatalf("read %s: %v", file.Path, err)
		}
		out[file.Path] = string(data)
	}
	return out
}
