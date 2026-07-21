package hooks

import (
	"bytes"
	"strings"
	"testing"
)

type stubInstaller struct {
	name           string
	uninstallCalls int
}

func (s *stubInstaller) Name() string                            { return s.name }
func (s *stubInstaller) InstallWithOptions(InstallOptions) error { return nil }
func (s *stubInstaller) Uninstall() error {
	s.uninstallCalls++
	return nil
}
func (s *stubInstaller) Status() Report {
	return Report{Agent: s.name, Status: StatusCurrent}
}

func TestManagerUninstallWithOptionsDryRunDoesNotUninstall(t *testing.T) {
	m := &Manager{installers: map[string]Installer{}}
	inst := &stubInstaller{name: "stub"}
	m.Register(inst)
	var log bytes.Buffer

	if err := m.UninstallWithOptions([]string{"stub"}, InstallOptions{DryRun: true, Log: &log}); err != nil {
		t.Fatalf("dry-run uninstall: %v", err)
	}

	if inst.uninstallCalls != 0 {
		t.Fatalf("dry-run called uninstall %d time(s)", inst.uninstallCalls)
	}
	if !strings.Contains(log.String(), "would uninstall stub hooks") {
		t.Fatalf("dry-run log = %q", log.String())
	}
}
