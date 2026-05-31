package hooks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func newTestOmpInstaller(t *testing.T) *OmpInstaller {
	t.Helper()
	return &OmpInstaller{AgentDir: filepath.Join(t.TempDir(), "agent")}
}

func TestOmpInstallIsIdempotentAndCurrent(t *testing.T) {
	o := newTestOmpInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("first install: %v", err)
	}
	first, err := os.ReadFile(o.sidecarPath())
	if err != nil {
		t.Fatalf("read sidecar after install: %v", err)
	}
	if string(first) != ompSidecarSource {
		t.Fatalf("installed sidecar does not match embedded source")
	}
	if got := o.Status(); got.Status != StatusCurrent {
		t.Fatalf("post-install status: %+v", got)
	}

	if err := o.Install(); err != nil {
		t.Fatalf("second install: %v", err)
	}
	second, err := os.ReadFile(o.sidecarPath())
	if err != nil {
		t.Fatalf("read sidecar after re-install: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("re-install changed sidecar body")
	}
}

func TestOmpStatusNotInstalledWhenAbsent(t *testing.T) {
	o := newTestOmpInstaller(t)
	if got := o.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("status: want %s, got %+v", StatusNotInstalled, got)
	}
}

func TestOmpStatusModifiedOnBodyDiff(t *testing.T) {
	o := newTestOmpInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := os.WriteFile(o.sidecarPath(), []byte("// hand-edited\n"), 0o644); err != nil {
		t.Fatalf("tamper sidecar: %v", err)
	}
	if got := o.Status(); got.Status != StatusModified {
		t.Fatalf("status: want %s, got %+v", StatusModified, got)
	}
}

func TestOmpUninstallRemovesSidecar(t *testing.T) {
	o := newTestOmpInstaller(t)
	if err := o.Install(); err != nil {
		t.Fatalf("install: %v", err)
	}
	if err := o.Uninstall(); err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	if _, err := os.Stat(o.sidecarPath()); !os.IsNotExist(err) {
		t.Errorf("sidecar still present (err=%v)", err)
	}
	if got := o.Status(); got.Status != StatusNotInstalled {
		t.Fatalf("post-uninstall status: %+v", got)
	}
}

func TestOmpSidecarEmbedsVersionMarker(t *testing.T) {
	want := `const SIDECAR_VERSION = "` + QuestmasterSidecarVersion + `";`
	if !strings.Contains(ompSidecarSource, want) {
		t.Fatalf("embedded omp sidecar missing version marker %q", QuestmasterSidecarVersion)
	}
}

func TestOmpRegisteredInManager(t *testing.T) {
	m := NewManager()
	if _, err := m.Resolve("omp"); err != nil {
		t.Fatalf("manager missing omp installer: %v", err)
	}
}
