package hooks

import (
	"errors"
	"os"
	"path/filepath"
)

// PiInstaller is a Phase 1 stub. PR-C fills in the activity-sidecar
// extension marker file and Pi-side wiring once the sidecar TS rewrite
// lands.
type PiInstaller struct {
	Home string
}

// NewPiInstaller resolves $PI_HOME / $HOME for the stub.
func NewPiInstaller(home string) *PiInstaller {
	if home == "" {
		home = os.Getenv("PI_HOME")
	}
	if home == "" {
		if h := os.Getenv("HOME"); h != "" {
			home = filepath.Join(h, ".pi")
		}
	}
	return &PiInstaller{Home: home}
}

// Name implements Installer.
func (p *PiInstaller) Name() string { return "pi" }

// Install is a stub; full implementation lands in PR-C.
func (p *PiInstaller) Install() error {
	return errors.New("pi installer: not yet implemented — see PR-B / PR-C")
}

// Uninstall is a stub; full implementation lands in PR-C.
func (p *PiInstaller) Uninstall() error {
	return errors.New("pi installer: not yet implemented — see PR-B / PR-C")
}

// Status returns NotInstalled until PR-C replaces this stub.
func (p *PiInstaller) Status() Report {
	return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "deferred to PR-C"}
}
