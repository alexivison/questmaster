package hooks

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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

func newTestPiInstaller(t *testing.T) *PiInstaller {
	t.Helper()
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "agent", "extensions"), 0o755); err != nil {
		t.Fatalf("mkdir pi extensions: %v", err)
	}
	return &PiInstaller{Home: home}
}

func TestPiInstallIsIdempotent(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(p.markerPath())
	if err != nil {
		t.Fatalf("read marker after first install: %v", err)
	}
	if string(first) != QuestmasterSidecarVersion {
		t.Fatalf("marker version: want %q, got %q", QuestmasterSidecarVersion, first)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
	}
	extension, err := os.ReadFile(p.extensionPath())
	if err != nil || !strings.Contains(string(extension), `deliverAs: "steer"`) {
		t.Fatalf("messaging extension = %q, err = %v", extension, err)
	}

	if err := p.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(p.markerPath())
	if err != nil {
		t.Fatalf("read marker after second install: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("re-install changed marker: first=%q second=%q", first, second)
	}
}

func TestPiInstallReplacesOutdatedExtension(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("initial install: %v", err)
	}
	if err := os.WriteFile(p.extensionPath(), []byte("old extension"), 0o644); err != nil {
		t.Fatalf("replace installed extension: %v", err)
	}
	if got := p.Status(); got.Status != StatusOutdated {
		t.Fatalf("status after extension change: %+v", got)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("upgrade install: %v", err)
	}
	data, err := os.ReadFile(p.extensionPath())
	if err != nil || string(data) != piMessagingExtension {
		t.Fatalf("installed extension = %q, err = %v", data, err)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("status after upgrade: %+v", got)
	}
}

func TestPiMarkerVersionMatchesExtension(t *testing.T) {
	want := `const sidecarVersion = "` + QuestmasterSidecarVersion + `";`
	if !strings.Contains(piMessagingExtension, want) {
		t.Fatalf("Pi extension marker does not match %q", QuestmasterSidecarVersion)
	}
}

func TestPiStatusOutdatedOnVersionMismatch(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := os.WriteFile(p.markerPath(), []byte("older-version"), 0o644); err != nil {
		t.Fatalf("seed marker: %v", err)
	}
	got := p.Status()
	if got.Status != StatusOutdated {
		t.Fatalf("status: want %s, got %+v", StatusOutdated, got)
	}
}

func TestPiStatusNotInstalledWhenMarkerAbsent(t *testing.T) {
	p := &PiInstaller{Home: t.TempDir()}
	got := p.Status()
	if got.Status != StatusNotInstalled {
		t.Fatalf("status: want %s, got %+v", StatusNotInstalled, got)
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

func TestPiUninstallRemovesMarker(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := p.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	for _, path := range p.markerPaths() {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("marker still present at %s (err=%v)", path, err)
		}
	}
	if _, err := os.Stat(p.extensionPath()); !os.IsNotExist(err) {
		t.Errorf("messaging extension still present: %v", err)
	}
	if got := p.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("post-uninstall status: %+v", got)
	}
}
