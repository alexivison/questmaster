package hooks

import (
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

func TestPiInstallIsIdempotent(t *testing.T) {
	p := newTestPiInstaller(t)
	if err := p.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(p.markerPath())
	if err != nil {
		t.Fatalf("read marker after first install: %v", err)
	}
	if string(first) != PartyCLISidecarVersion {
		t.Fatalf("marker version: want %q, got %q", PartyCLISidecarVersion, first)
	}
	if got := p.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
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

func TestPiSidecarVersionMatchesExtension(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "pi", "agent", "extensions", "activity-sidecar.ts"))
	if os.IsNotExist(err) {
		t.Skip("activity-sidecar.ts is outside tools/party-cli and absent in standalone extracts")
	}
	if err != nil {
		t.Fatalf("read activity-sidecar.ts: %v", err)
	}
	want := `const SIDECAR_VERSION = "` + PartyCLISidecarVersion + `";`
	if !strings.Contains(string(data), want) {
		t.Fatalf("activity-sidecar.ts version marker does not match %q", PartyCLISidecarVersion)
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
	if got := p.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("post-uninstall status: %+v", got)
	}
}
