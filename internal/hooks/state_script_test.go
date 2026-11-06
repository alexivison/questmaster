package hooks

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The v1 script threw the binary's stderr away. hooks status must report a
// v1 install as not current, and install must replace it with the current
// script.
func TestHooksStatusReportsV1ScriptStaleAndInstallReplacesIt(t *testing.T) {
	v1, err := os.ReadFile(filepath.Join("testdata", "questmaster-state-v1.sh"))
	if err != nil {
		t.Fatalf("read v1 script fixture: %v", err)
	}
	claude := newTestClaudeInstaller(t)
	codex := newTestCodexInstaller(t)
	writeCodexConfig(t, codex, true)
	for _, tc := range []struct {
		agent     string
		installer Installer
		script    string
	}{
		{"claude", claude, claude.scriptPath()},
		{"codex", codex, codex.scriptPath()},
	} {
		t.Run(tc.agent, func(t *testing.T) {
			if err := tc.installer.InstallWithOptions(InstallOptions{}); err != nil {
				t.Fatalf("install: %v", err)
			}
			if got := tc.installer.Status(); got.Status != StatusCurrent {
				t.Fatalf("status after install = %+v, want current", got)
			}
			if err := os.WriteFile(tc.script, []byte(strings.ReplaceAll(string(v1), "__AGENT__", tc.agent)), 0o755); err != nil {
				t.Fatalf("write v1 script: %v", err)
			}
			if got := tc.installer.Status(); got.Status == StatusCurrent {
				t.Fatalf("status with the v1 script = %+v, want not current", got)
			}
			if err := tc.installer.InstallWithOptions(InstallOptions{}); err != nil {
				t.Fatalf("reinstall: %v", err)
			}
			if got := tc.installer.Status(); got.Status != StatusCurrent {
				t.Fatalf("status after reinstall = %+v, want current", got)
			}
			if data, err := os.ReadFile(tc.script); err != nil || string(data) != RenderScript(tc.agent) {
				t.Fatalf("script after reinstall is not the current one (err %v)", err)
			}
		})
	}
}

type stateScriptRun struct {
	stdout string
	log    string
}

// runStateScript runs the rendered Claude script the way Claude does: with
// the action as $1 and the hook payload on stdin.
func runStateScript(t *testing.T, env ...string) stateScriptRun {
	t.Helper()
	dir := t.TempDir()
	root := filepath.Join(dir, "state")
	script := filepath.Join(dir, "questmaster-state.sh")
	if err := os.WriteFile(script, []byte(RenderScript("claude")), 0o755); err != nil {
		t.Fatalf("write script: %v", err)
	}
	cmd := exec.Command("/bin/sh", script, "working")
	cmd.Env = append([]string{
		"PATH=/usr/bin:/bin",
		"HOME=" + dir,
		"QUESTMASTER_SESSION=qm-script",
		"QUESTMASTER_STATE_ROOT=" + root,
	}, env...)
	cmd.Stdin = strings.NewReader(`{"prompt":"hello"}`)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		t.Fatalf("hook script failed, but it must always exit 0: %v", err)
	}
	log, err := os.ReadFile(filepath.Join(root, "qm-script", "hook-errors.log"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("read hook-errors.log: %v", err)
	}
	return stateScriptRun{stdout: stdout.String(), log: string(log)}
}

func writeFakeBinary(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "qm")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatalf("write fake binary: %v", err)
	}
	return path
}

func TestStateScriptLogsMissingBinary(t *testing.T) {
	run := runStateScript(t)
	if strings.TrimSpace(run.stdout) != "{}" {
		t.Fatalf("stdout = %q, want {}", run.stdout)
	}
	if !strings.Contains(run.log, "binary not found") || !strings.Contains(run.log, "claude/working") {
		t.Fatalf("hook-errors.log = %q, want a tagged binary-not-found line", run.log)
	}
}

func TestStateScriptLogsFailedRun(t *testing.T) {
	bin := writeFakeBinary(t, "cat >/dev/null\necho 'panic: example failure' >&2\nexit 3")
	run := runStateScript(t, "QUESTMASTER_BIN="+bin)
	if strings.TrimSpace(run.stdout) != "{}" {
		t.Fatalf("stdout = %q, want {}", run.stdout)
	}
	if !strings.Contains(run.log, "exit 3") || !strings.Contains(run.log, "panic: example failure") {
		t.Fatalf("hook-errors.log = %q, want the exit status and the binary's stderr", run.log)
	}
}

// A run that exits 0 has already logged its own handler errors, so the
// script adds nothing.
func TestStateScriptPassesPayloadAndStaysQuietOnSuccess(t *testing.T) {
	dir := t.TempDir()
	bin := writeFakeBinary(t, `cat > "`+filepath.Join(dir, "stdin")+`"
printf '%s\n' "$@" > "`+filepath.Join(dir, "argv")+`"
echo 'handled error already logged by the binary' >&2`)
	run := runStateScript(t, "QUESTMASTER_BIN="+bin)
	if run.log != "" {
		t.Fatalf("hook-errors.log = %q after a successful run, want nothing", run.log)
	}
	stdin, err := os.ReadFile(filepath.Join(dir, "stdin"))
	if err != nil || !json.Valid(stdin) {
		t.Fatalf("payload reached the binary as %q (err %v)", stdin, err)
	}
	argv, err := os.ReadFile(filepath.Join(dir, "argv"))
	if err != nil || strings.Join(strings.Fields(string(argv)), " ") != "hook --session qm-script claude working" {
		t.Fatalf("binary argv = %q (err %v)", argv, err)
	}
}
