package hooks

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"
	"time"

	qmagent "github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/fsnotify/fsnotify"
)

const openCodeGateWaitTimeout = 20 * time.Second

func runOpenCodeHookStub() int {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		return 1
	}
	var payload struct {
		Event struct {
			Type string `json:"type"`
		} `json:"event"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return 1
	}
	root, event := os.Getenv("QM_CAPTURE"), payload.Event.Type
	log := func(name string) error { return appendOpenCodeCaptureLog(root, name) }
	if event == "tool.execute.before" {
		watcher, err := fsnotify.NewWatcher()
		if err != nil {
			return 1
		}
		defer watcher.Close()
		if err := watcher.Add(root); err != nil {
			return 1
		}
		if err := writeOpenCodeCaptureFile(root, "before-started", nil); err != nil {
			return 1
		}
		timer := time.NewTimer(openCodeGateWaitTimeout)
		defer timer.Stop()
	waitForRelease:
		for {
			select {
			case event, ok := <-watcher.Events:
				if !ok {
					return 1
				}
				if filepath.Clean(event.Name) == filepath.Join(root, "before-release") {
					break waitForRelease
				}
			case <-timer.C:
				return 1
			case err, ok := <-watcher.Errors:
				if !ok || err != nil {
					return 1
				}
			}
		}
	}
	var signals chan os.Signal
	if event == "test.timeout" {
		signals = make(chan os.Signal, 1)
		signal.Notify(signals, syscall.SIGTERM)
	}
	if err := log(event); err != nil {
		return 1
	}
	if event == "test.timeout" {
		<-signals
		if err := log("test.timeout.sigterm"); err != nil {
			return 1
		}
		select {}
	}
	if err := writeOpenCodeCaptureFile(root, event+".json", data); err != nil {
		return 1
	}
	return 0
}

// Publish complete snapshots so filesystem watchers cannot observe a created but partially written capture file.
func writeOpenCodeCaptureFile(root, name string, data []byte) error {
	temp, err := os.CreateTemp(root, ".capture-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	return os.Rename(tempPath, filepath.Join(root, name))
}

func appendOpenCodeCaptureLog(root, name string) error {
	path := filepath.Join(root, "order.log")
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	data = fmt.Appendf(data, "%s:%d\n", name, time.Now().UnixMilli())
	return writeOpenCodeCaptureFile(root, "order.log", data)
}

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

func TestOpenCodeInstallPopulatesClassMasterAgents(t *testing.T) {
	o := newTestOpenCodeInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}

	masterPrompt := qmagent.NewOpenCode(qmagent.AgentConfig{}).MasterPrompt()
	for _, class := range qmagent.VoiceClasses() {
		t.Run(class, func(t *testing.T) {
			t.Parallel()
			path := o.agentPath(qmagent.OpenCodeMasterClassAgentName(class))
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read class master agent %s: %v", class, err)
			}
			body := string(data)
			for _, want := range []string{masterPrompt, qmagent.ClassVoice(class)} {
				if !strings.Contains(body, want) {
					t.Fatalf("class master agent %s missing prompt text %q", class, want)
				}
			}
		})
	}

	masterData, err := os.ReadFile(o.agentPath(qmagent.OpenCodeMasterAgentName))
	if err != nil {
		t.Fatalf("read classless master agent: %v", err)
	}
	if strings.Contains(string(masterData), "Your session class is the") {
		t.Fatal("OpenCode classless master agent contains class voice")
	}

	workerData, err := os.ReadFile(o.agentPath(qmagent.OpenCodeWorkerAgentName))
	if err != nil {
		t.Fatalf("read worker agent: %v", err)
	}
	if strings.Contains(string(workerData), "Your session class is the") {
		t.Fatal("OpenCode worker agent contains master class voice")
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
	plugin := strings.ReplaceAll(openCodePluginSource, "const EMIT_TIMEOUT_MS = 5000;", "const EMIT_TIMEOUT_MS = 1000;")
	plugin = strings.ReplaceAll(plugin, "const EMIT_KILL_GRACE_MS = 1000;", "const EMIT_KILL_GRACE_MS = 100;")
	if plugin == openCodePluginSource {
		t.Fatal("plugin timeout constants were not replaced for the test")
	}
	if err := os.WriteFile(pluginPath, []byte(plugin), 0o600); err != nil {
		t.Fatalf("write plugin: %v", err)
	}
	stubPath, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	captureDir := filepath.Join(dir, "capture")
	if err := os.Mkdir(captureDir, 0o700); err != nil {
		t.Fatalf("create capture dir: %v", err)
	}
	script := `import assert from "node:assert/strict";
import { existsSync, readFileSync, watch, writeFileSync } from "node:fs";
import { basename, dirname } from "node:path";
import { pathToFileURL } from "node:url";
const { QuestmasterOpenCode } = await import(pathToFileURL(process.env.QM_PLUGIN));
const hooks = await QuestmasterOpenCode();
const waitForFile = (path) => new Promise((resolve, reject) => {
  if (existsSync(path)) return resolve();
  const watcher = watch(dirname(path), (_event, filename) => {
    if (String(filename) === basename(path) && existsSync(path)) { watcher.close(); resolve(); }
  });
  watcher.once("error", (error) => { watcher.close(); reject(error); });
  if (existsSync(path)) { watcher.close(); resolve(); }
});
const input = { tool: "bash", sessionID: "ses-1", callID: "call-1" };
const args = { command: "go test ./..." };
let beforeReturned = false;
const beforeStarted = waitForFile(process.env.QM_CAPTURE + "/before-started");
const beforeCall = hooks["tool.execute.before"](input, { args }).then(() => { beforeReturned = true; });
await beforeStarted;
const wasAsync = beforeReturned;
writeFileSync(process.env.QM_CAPTURE + "/before-release", "");
await beforeCall;
assert.ok(wasAsync, "before hook awaited the emission queue");
await hooks["tool.execute.after"]({ ...input, args }, { title: "bash", output: "", metadata: { sessionId: "ses-child" } });
const failedPart = { type: "message.part.updated", properties: { part: { id: "prt-1", callID: "call-1", type: "tool", state: { status: "error" } } } };
await hooks.event({ event: failedPart });
const wait = async (name) => {
  const path = process.env.QM_CAPTURE + "/" + name + ".json";
  await waitForFile(path);
  return JSON.parse(readFileSync(path, "utf8"));
};
const before = await wait("tool.execute.before");
const after = await wait("tool.execute.after");
const failed = await wait("message.part.updated");
assert.deepEqual(before.event.properties, { ...input, args: { command: args.command } });
assert.deepEqual(after.event.properties, { ...input, metadata: { sessionId: "ses-child" } });
assert.deepEqual(failed.event, failedPart);
const afterTimeout = new Promise((resolve, reject) => {
  const path = process.env.QM_CAPTURE + "/order.log";
  const lines = () => readFileSync(path, "utf8").trim().split("\n");
  const hasEntry = () => lines().some((line) => line.startsWith("test.after-timeout:"));
  if (hasEntry()) return resolve(lines());
  const watcher = watch(process.env.QM_CAPTURE, (_event, filename) => {
    if (String(filename) === "order.log" && hasEntry()) { watcher.close(); resolve(lines()); }
  });
  watcher.once("error", (error) => { watcher.close(); reject(error); });
  if (hasEntry()) { watcher.close(); resolve(lines()); }
});
await hooks.event({ event: { type: "test.timeout" } });
await hooks.event({ event: { type: "test.after-timeout" } });
const lines = await afterTimeout;
const at = (prefix) => Number(lines.find((line) => line.startsWith(prefix + ":"))?.split(":")[1]);
assert.ok(at("test.timeout") > 0 && at("test.timeout.sigterm") > 0 && at("test.after-timeout") > 0, "timeout path did not signal and continue");
assert.ok(at("test.timeout.sigterm") - at("test.timeout") >= 70, "queue advanced before the timeout kill grace elapsed");
assert.ok(at("test.after-timeout") - at("test.timeout.sigterm") >= 70, "queue advanced before the timed-out child closed");
assert.deepEqual(lines.slice(0, 3).map((line) => line.split(":")[0]), ["tool.execute.before", "tool.execute.after", "message.part.updated"]);
assert.ok(lines.indexOf(lines.find((line) => line.startsWith("test.timeout:"))) < lines.indexOf(lines.find((line) => line.startsWith("test.after-timeout:"))), "next event overtook the timed-out child");
`
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, node, "--input-type=module", "-e", script)
	cmd.Env = append(os.Environ(),
		"QM_OPENCODE_HOOK_STUB=1",
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
