package hooks

import (
	"bytes"
	"context"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if os.Getenv("QM_OPENCODE_HOOK_STUB") == "1" {
		os.Exit(runOpenCodeHookStub())
	}
	root, err := os.MkdirTemp("", "qm-hooks-state-*")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("QUESTMASTER_STATE_ROOT", root); err != nil {
		panic(err)
	}
	// Pin the Pi locations so no test reads or retires a developer's real Pi config.
	piRoot, err := os.MkdirTemp("", "qm-hooks-pi-*")
	if err != nil {
		panic(err)
	}
	if err := os.Setenv("PI_HOME", filepath.Join(piRoot, "home")); err != nil {
		panic(err)
	}
	if err := os.Setenv("PI_CODING_AGENT_DIR", filepath.Join(piRoot, "agent")); err != nil {
		panic(err)
	}
	code := m.Run()
	_ = os.RemoveAll(root)
	_ = os.RemoveAll(piRoot)
	os.Exit(code)
}

func TestPiMessagingSocketOwnership(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	if err := exec.Command(node, "--experimental-strip-types", "-e", "").Run(); err != nil {
		t.Skip("Node TypeScript type stripping is unavailable")
	}
	extension, err := filepath.Abs(filepath.Join("assets", "questmaster-pi-messaging.ts"))
	if err != nil {
		t.Fatal(err)
	}
	binDir := t.TempDir()
	build := exec.CommandContext(t.Context(), "go", "build", "-buildvcs=false", "-o", filepath.Join(binDir, "questmaster"), "../..")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build test hook binary: %v\n%s", err, output)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, node, "--experimental-strip-types", filepath.Join("testdata", "pi_socket_ownership.mjs"), extension).CombinedOutput()
	if err != nil {
		t.Fatalf("Pi socket ownership check: %v\n%s", err, out)
	}
}

func TestPiActivityForwardingUsesDiscreteHooks(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	if err := exec.Command(node, "--experimental-strip-types", "-e", "").Run(); err != nil {
		t.Skip("Node TypeScript type stripping is unavailable")
	}
	extension, err := filepath.Abs(filepath.Join("assets", "questmaster-pi-messaging.ts"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, node, "--experimental-strip-types", filepath.Join("testdata", "pi_activity.mjs"), extension).CombinedOutput()
	if err != nil {
		t.Fatalf("Pi activity extension check: %v\n%s", err, out)
	}
}

func TestPiActivityQueueBatchesSlowHookCalls(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	if err := exec.Command(node, "--experimental-strip-types", "-e", "").Run(); err != nil {
		t.Skip("Node TypeScript type stripping is unavailable")
	}
	extension, err := filepath.Abs(filepath.Join("assets", "questmaster-pi-messaging.ts"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, node, "--experimental-strip-types", filepath.Join("testdata", "pi_hook_queue.mjs"), extension).CombinedOutput()
	if err != nil {
		t.Fatalf("Pi hook queue check: %v\n%s", err, out)
	}
}

func TestPiActivityHookUsesQuestmasterBinAndWaitsForBoundedHook(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	if err := exec.Command(node, "--experimental-strip-types", "-e", "").Run(); err != nil {
		t.Skip("Node TypeScript type stripping is unavailable")
	}
	extension, err := filepath.Abs(filepath.Join("assets", "questmaster-pi-messaging.ts"))
	if err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(t.TempDir(), "qm")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, node, "--experimental-strip-types", filepath.Join("testdata", "pi_hook_bin.mjs"), extension, binary).CombinedOutput()
	if err != nil {
		t.Fatalf("Pi hook binary check: %v\n%s", err, out)
	}
}

// legacyPiCopy carries the two marks an older installer's copy has.
const legacyPiCopy = `const sessionID = process.env.QUESTMASTER_SESSION ?? "";
spawn("questmaster", ["hook", "pi", action], { stdio: ["pipe", "ignore", "ignore"] });
`

// newTestPiInstaller returns an installer with a Pi home holding agent/extensions
// and an owned extension dir that does not exist yet.
func newTestPiInstaller(t *testing.T) *PiInstaller {
	t.Helper()
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "agent", "extensions"), 0o755); err != nil {
		t.Fatalf("mkdir pi extensions: %v", err)
	}
	return &PiInstaller{Home: home, ExtensionDir: filepath.Join(t.TempDir(), "pi")}
}

func writeTestFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

// writeLegacyPiFiles seeds an older installer's copy and marker in dir.
func writeLegacyPiFiles(t *testing.T, dir string) (extension, marker string) {
	t.Helper()
	extension = filepath.Join(dir, "questmaster-messaging.ts")
	marker = filepath.Join(dir, ".questmaster-installed")
	writeTestFile(t, extension, legacyPiCopy)
	writeTestFile(t, marker, "phase2-v3\n")
	return extension, marker
}

func assertGone(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Errorf("%s still present (err=%v)", path, err)
	}
}

func TestPiInstallWritesOwnedExtension(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	data, err := os.ReadFile(p.extensionFile())
	if err != nil || string(data) != piMessagingExtension {
		t.Fatalf("owned extension = %q, err = %v", data, err)
	}
	fileInfo, err := os.Stat(p.extensionFile())
	if err != nil {
		t.Fatalf("stat owned extension: %v", err)
	}
	if got := fileInfo.Mode().Perm(); got != 0o600 {
		t.Errorf("owned extension mode = %o, want 600", got)
	}
	dirInfo, err := os.Stat(p.ExtensionDir)
	if err != nil {
		t.Fatalf("stat owned extension dir: %v", err)
	}
	if got := dirInfo.Mode().Perm(); got != 0o700 {
		t.Errorf("owned extension dir mode = %o, want 700", got)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
	}
	if err := filepath.WalkDir(p.Home, func(path string, d fs.DirEntry, err error) error {
		if err == nil && d.Name() == ".questmaster-installed" {
			t.Errorf("install wrote a marker at %s", path)
		}
		return err
	}); err != nil {
		t.Fatalf("walk Pi home: %v", err)
	}
}

func TestPiInstallLeavesCurrentExtensionUntouched(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	past := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(p.extensionFile(), past, past); err != nil {
		t.Fatalf("age owned extension: %v", err)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	info, err := os.Stat(p.extensionFile())
	if err != nil {
		t.Fatalf("stat owned extension: %v", err)
	}
	if !info.ModTime().Equal(past) {
		t.Errorf("re-install rewrote the owned extension: mtime = %v", info.ModTime())
	}
}

func TestPiInstallRewritesModifiedExtension(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("initial install: %v", err)
	}
	writeTestFile(t, p.extensionFile(), "old extension")
	if got := p.Status(); got.Status != StatusOutdated {
		t.Fatalf("status after extension change: %+v", got)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("upgrade install: %v", err)
	}
	data, err := os.ReadFile(p.extensionFile())
	if err != nil || string(data) != piMessagingExtension {
		t.Fatalf("installed extension = %q, err = %v", data, err)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("status after upgrade: %+v", got)
	}
}

func TestPiStatusTracksOwnedExtension(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		seed       func(t *testing.T, p *PiInstaller)
		wantStatus Status
		wantDetail string
	}{
		{
			name:       "missing",
			seed:       func(t *testing.T, p *PiInstaller) {},
			wantStatus: StatusNotInstalled,
			wantDetail: "written at the next Pi launch",
		},
		{
			name:       "modified",
			seed:       func(t *testing.T, p *PiInstaller) { writeTestFile(t, p.extensionFile(), "old extension") },
			wantStatus: StatusOutdated,
			wantDetail: "is out of date",
		},
		{
			name: "current",
			seed: func(t *testing.T, p *PiInstaller) {
				if err := p.Install(); err != nil {
					t.Fatalf("install: %v", err)
				}
			},
			wantStatus: StatusCurrent,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			p := newTestPiInstaller(t)
			tt.seed(t, p)
			got := p.Status()
			if got.Status != tt.wantStatus || !strings.Contains(got.Detail, tt.wantDetail) {
				t.Fatalf("status = %+v, want %s with detail containing %q", got, tt.wantStatus, tt.wantDetail)
			}
		})
	}
}

func TestPiInstallerNeedsResolvedDirs(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	noExtensionDir := &PiInstaller{Home: home}
	if err := noExtensionDir.Install(); err == nil {
		t.Errorf("install without an extension dir succeeded")
	}
	if got := noExtensionDir.Status(); got.Status != StatusNotInstalled {
		t.Errorf("status without an extension dir: %+v", got)
	}
	noHome := &PiInstaller{ExtensionDir: filepath.Join(home, "pi")}
	if err := noHome.Install(); err == nil {
		t.Errorf("install without a Pi home succeeded")
	}
	if got := noHome.Status(); got.Status != StatusNotInstalled || got.Detail != "home dir not resolved" {
		t.Errorf("status without a Pi home: %+v", got)
	}
}

// TestPiLegacyCopiesRetiredByInstallAndUninstall covers each directory an older
// installer may have written to. It sets PI_CODING_AGENT_DIR, so it is not
// parallel.
func TestPiLegacyCopiesRetiredByInstallAndUninstall(t *testing.T) {
	tests := []struct {
		name string
		dir  func(home, coding string) string
	}{
		{"agent extensions", func(home, _ string) string { return filepath.Join(home, "agent", "extensions") }},
		{"root extensions", func(home, _ string) string { return filepath.Join(home, "extensions") }},
		{"coding agent dir", func(_, coding string) string { return filepath.Join(coding, "extensions") }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			coding := t.TempDir()
			t.Setenv("PI_CODING_AGENT_DIR", coding)
			p := newTestPiInstaller(t)
			extension, marker := writeLegacyPiFiles(t, tt.dir(p.Home, coding))

			if got := p.Status(); got.Status != StatusOutdated || !strings.Contains(got.Detail, "questmaster hooks install pi") {
				t.Fatalf("status with legacy copy: %+v", got)
			}
			if err := p.Install(); err != nil {
				t.Fatalf("install: %v", err)
			}
			assertGone(t, extension)
			assertGone(t, marker)
			if got := p.Status(); got.Status != StatusCurrent {
				t.Fatalf("status after install: %+v", got)
			}

			extension, marker = writeLegacyPiFiles(t, tt.dir(p.Home, coding))
			if err := p.Uninstall(); err != nil {
				t.Fatalf("uninstall: %v", err)
			}
			assertGone(t, extension)
			assertGone(t, marker)
			assertGone(t, p.extensionFile())
			if got := p.Status(); got.Status != StatusNotInstalled {
				t.Fatalf("status after uninstall: %+v", got)
			}
		})
	}
}

// The first installed copy only read QUESTMASTER_SESSION and never called the
// hook. It still loads beside the owned extension, so it must be retired too.
func TestPiLegacyMessagingOnlyCopyIsRetired(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	dir := filepath.Join(p.Home, "agent", "extensions")
	extension := filepath.Join(dir, "questmaster-messaging.ts")
	marker := filepath.Join(dir, ".questmaster-installed")
	writeTestFile(t, extension, "const sessionID = process.env.QUESTMASTER_SESSION ?? \"\";\n")
	writeTestFile(t, marker, "phase2-v2\n")
	if got := p.Status(); got.Status != StatusOutdated {
		t.Fatalf("status with messaging-only copy: %+v", got)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	assertGone(t, extension)
	assertGone(t, marker)
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("status after retiring messaging-only copy: %+v", got)
	}
}

func TestPiLegacyRetirementLeavesUserFilesAlone(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	dir := filepath.Join(p.Home, "agent", "extensions")
	userExtension := filepath.Join(dir, "questmaster-messaging.ts")
	userMarker := filepath.Join(dir, ".questmaster-installed")
	writeTestFile(t, userExtension, "// my own Pi extension\n")
	writeTestFile(t, userMarker, "keep me\n")

	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("user files changed status: %+v", got)
	}
	if err := p.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	for _, path := range []string{userExtension, userMarker} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("removed user file %s: %v", path, err)
		}
	}
}

func TestPiLegacySymlinkIsReportedNotRemoved(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	target := filepath.Join(t.TempDir(), "questmaster-messaging.ts")
	writeTestFile(t, target, legacyPiCopy)
	link := filepath.Join(p.Home, "agent", "extensions", "questmaster-messaging.ts")
	if err := os.Symlink(target, link); err != nil {
		t.Fatalf("symlink legacy copy: %v", err)
	}

	if got := p.Status(); got.Status != StatusOutdated || !strings.Contains(got.Detail, "left in place") {
		t.Fatalf("status with legacy symlink: %+v", got)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&fs.ModeSymlink == 0 {
		t.Fatalf("install changed the legacy symlink: info = %v, err = %v", info, err)
	}
	if got := p.Status(); got.Status != StatusOutdated || !strings.Contains(got.Detail, "left in place") {
		t.Fatalf("status after install with legacy symlink: %+v", got)
	}
	if err := p.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Lstat(link); err != nil {
		t.Fatalf("uninstall removed the legacy symlink: %v", err)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("symlink target removed: %v", err)
	}
}

func TestPiInstallDryRunTouchesNothing(t *testing.T) {
	t.Parallel()
	p := newTestPiInstaller(t)
	extension, marker := writeLegacyPiFiles(t, filepath.Join(p.Home, "agent", "extensions"))

	var log bytes.Buffer
	if err := p.InstallWithOptions(InstallOptions{DryRun: true, Log: &log}); err != nil {
		t.Fatalf("dry-run install: %v", err)
	}
	for _, want := range []string{
		"would remove legacy Pi file " + extension,
		"would remove legacy Pi file " + marker,
		"would write Pi extension " + p.extensionFile(),
	} {
		if !strings.Contains(log.String(), want) {
			t.Errorf("dry-run log missing %q: %q", want, log.String())
		}
	}
	for _, path := range []string{extension, marker} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("dry-run removed %s: %v", path, err)
		}
	}
	if _, err := os.Stat(p.ExtensionDir); !os.IsNotExist(err) {
		t.Errorf("dry-run created %s (err=%v)", p.ExtensionDir, err)
	}
}

func TestPiLegacySidecarWarnsOnInstallAndStatus(t *testing.T) {
	t.Setenv("PI_CODING_AGENT_DIR", "")
	p := newTestPiInstaller(t)
	legacy := filepath.Join(p.Home, "agent", "extensions", "activity-sidecar.ts")
	settings := filepath.Join(p.Home, "agent", "settings.json")
	if err := os.WriteFile(legacy, []byte("legacy extension"), 0o644); err != nil {
		t.Fatalf("write legacy sidecar: %v", err)
	}
	if err := os.WriteFile(settings, []byte(`{"extensions":["extensions/activity-sidecar.ts"]}`), 0o644); err != nil {
		t.Fatalf("write Pi settings: %v", err)
	}
	if got := p.Status(); got.Status != StatusOutdated || !strings.Contains(got.Detail, "remove the activity-sidecar.ts file") {
		t.Fatalf("status with legacy sidecar: %+v", got)
	}

	var log bytes.Buffer
	if err := p.InstallWithOptions(InstallOptions{Log: &log}); err != nil {
		t.Fatalf("install alongside legacy sidecar: %v", err)
	}
	if !strings.Contains(log.String(), "warning: legacy Pi activity sidecar detected") || !strings.Contains(log.String(), settings) {
		t.Fatalf("install warning = %q", log.String())
	}
	for _, path := range []string{legacy, settings} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("install removed legacy file %s: %v", path, err)
		}
	}
}

// TestPiMessagingExtensionBridgesSubagents keeps the sub-agent wiring the
// extension must forward to `questmaster hook`.
func TestPiMessagingExtensionBridgesSubagents(t *testing.T) {
	t.Parallel()
	for _, hook := range []string{
		`subagentEvents?.on?.("subagents:started", forwardSubagent("subagent_start"));`,
		`subagentEvents?.on?.("subagents:completed", forwardSubagent("subagent_stop"));`,
		`subagentEvents?.on?.("subagents:failed", forwardSubagent("subagent_stop"));`,
	} {
		if !strings.Contains(piMessagingExtension, hook) {
			t.Errorf("Pi extension missing sub-agent bridge %q", hook)
		}
	}
}
