package hooks

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestPiInstaller(t *testing.T) *PiInstaller {
	t.Helper()
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, "agent", "extensions"), 0o755); err != nil {
		t.Fatalf("mkdir pi extensions: %v", err)
	}
	return &PiInstaller{Home: home}
}

func TestPiInstallIsIdempotentAndPreservesLegacyMarker(t *testing.T) {
	p := newTestPiInstaller(t)
	marker := filepath.Join(p.Home, "agent", "extensions", ".questmaster-installed")
	if err := os.WriteFile(marker, []byte("legacy-sidecar"), 0o644); err != nil {
		t.Fatalf("write legacy marker: %v", err)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(p.extensionPath())
	if err != nil {
		t.Fatalf("read extension after first install: %v", err)
	}
	if string(first) != piMessagingExtensionSource {
		t.Fatal("installed extension differs from embedded source")
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
	}

	if err := p.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(p.extensionPath())
	if err != nil {
		t.Fatalf("read extension after second install: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Errorf("re-install changed extension")
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != "legacy-sidecar" {
		t.Fatalf("legacy marker changed: %q, %v", got, err)
	}
}

func TestPiInstallUsesConfiguredAgentDirectory(t *testing.T) {
	agentDir := t.TempDir()
	p := &PiInstaller{AgentDir: agentDir}
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	path := filepath.Join(agentDir, "extensions", piMessagingExtensionFileName)
	if got, err := os.ReadFile(path); err != nil || string(got) != piMessagingExtensionSource {
		t.Fatalf("configured extension = %q, %v", got, err)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("status: %+v", got)
	}
}

func TestNewPiInstallerUsesConfiguredAgentDirectory(t *testing.T) {
	agentDir := t.TempDir()
	t.Setenv("PI_CODING_AGENT_DIR", agentDir)
	p := NewPiInstaller("")
	if got := p.extensionPath(); got != filepath.Join(agentDir, "extensions", piMessagingExtensionFileName) {
		t.Fatalf("extension path = %q", got)
	}
}

func TestNewPiInstallerExpandsTildeAndIgnoresPiHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PI_HOME", t.TempDir())
	t.Setenv("PI_CODING_AGENT_DIR", "~/custom-agent")
	p := NewPiInstaller("")
	if got, want := p.extensionPath(), filepath.Join(home, "custom-agent", "extensions", piMessagingExtensionFileName); got != want {
		t.Fatalf("tilde extension path = %q, want %q", got, want)
	}

	t.Setenv("PI_CODING_AGENT_DIR", "")
	p = NewPiInstaller("")
	if got, want := p.extensionPath(), filepath.Join(home, ".pi", "agent", "extensions", piMessagingExtensionFileName); got != want {
		t.Fatalf("default extension path = %q, want %q", got, want)
	}
}

func TestPiMessagingExtensionUsesVerifiedLifecycleContract(t *testing.T) {
	for _, want := range []string{
		`pi.on("session_start"`,
		`pi.on("session_shutdown"`,
		`join("/tmp", sessionID, "pi.sock")`,
		"lstat(path)",
		"runtime.mode & 0o022",
		"process.umask(0o077)",
		"chmod(socketPath, 0o600)",
		"maxRequestBytes = 1 << 20",
		`typeof pi.sendUserMessage !== "function"`,
		`pi.sendUserMessage(request.message, { deliverAs: "steer" })`,
		`status: "unconfirmed"`,
	} {
		if !strings.Contains(piMessagingExtensionSource, want) {
			t.Fatalf("embedded Pi messaging extension missing %q", want)
		}
	}
	guard := strings.Index(piMessagingExtensionSource, `typeof pi.sendUserMessage !== "function"`)
	listener := strings.Index(piMessagingExtensionSource, `pi.on("session_start"`)
	if guard < 0 || listener < 0 || guard > listener {
		t.Fatal("Pi capability check must run before the extension registers lifecycle hooks")
	}
}

func TestPiStatusModifiedWhenExtensionDiffers(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := os.WriteFile(p.extensionPath(), []byte("modified"), 0o644); err != nil {
		t.Fatalf("write extension: %v", err)
	}
	if got := p.Status(); got.Status != StatusModified {
		t.Fatalf("status: want %s, got %+v", StatusModified, got)
	}
}

func TestPiStatusNotInstalledWhenExtensionAbsent(t *testing.T) {
	p := &PiInstaller{Home: t.TempDir()}
	if got := p.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("status: want %s, got %+v", StatusNotInstalled, got)
	}
}

func TestPiUninstallRemovesOnlyMessagingExtension(t *testing.T) {
	p := newTestPiInstaller(t)
	marker := filepath.Join(p.Home, "agent", "extensions", ".questmaster-installed")
	if err := os.WriteFile(marker, []byte("legacy-sidecar"), 0o644); err != nil {
		t.Fatalf("write legacy marker: %v", err)
	}
	if err := p.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := p.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(p.extensionPath()); !os.IsNotExist(err) {
		t.Errorf("extension still present (err=%v)", err)
	}
	if got, err := os.ReadFile(marker); err != nil || string(got) != "legacy-sidecar" {
		t.Fatalf("legacy marker changed: %q, %v", got, err)
	}
	if got := p.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("post-uninstall status: %+v", got)
	}
}
