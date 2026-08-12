package hooks

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const piMessagingExtensionFileName = "questmaster-messaging.ts"

//go:embed assets/questmaster-pi-messaging.ts
var piMessagingExtensionSource string

// PiInstaller manages Questmaster's Pi messaging extension. The legacy
// activity-sidecar marker is shared state and intentionally left untouched.
type PiInstaller struct {
	// Home is Pi's config root. Override only in tests.
	Home string
	// AgentDir is Pi's resolved agent config directory. Override only in tests.
	AgentDir string
}

// NewPiInstaller resolves Pi's agent configuration directory.
func NewPiInstaller(home string) *PiInstaller {
	if home == "" {
		if agentDir := os.Getenv("PI_CODING_AGENT_DIR"); agentDir != "" {
			return &PiInstaller{AgentDir: expandPiTilde(agentDir)}
		}
		if userHome, err := os.UserHomeDir(); err == nil {
			home = filepath.Join(userHome, ".pi")
		}
	}
	return &PiInstaller{Home: home}
}

func expandPiTilde(path string) string {
	if path != "~" && !strings.HasPrefix(path, "~/") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == "~" {
		return home
	}
	return filepath.Join(home, path[2:])
}

// Name implements Installer.
func (p *PiInstaller) Name() string { return "pi" }

func (p *PiInstaller) agentDir() string {
	if p.AgentDir != "" {
		return p.AgentDir
	}
	if p.Home == "" {
		return ""
	}
	return filepath.Join(p.Home, "agent")
}

func (p *PiInstaller) extensionPath() string {
	return filepath.Join(p.agentDir(), "extensions", piMessagingExtensionFileName)
}

// Install implements Installer.
func (p *PiInstaller) Install() error { return p.InstallWithOptions(InstallOptions{}) }

// InstallWithOptions writes only the Questmaster-owned extension source.
func (p *PiInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if p.agentDir() == "" {
		return errors.New("pi agent dir not resolved (set $PI_CODING_AGENT_DIR or $HOME)")
	}
	path := p.extensionPath()
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would write Pi messaging extension %s", path)
		return nil
	}
	if existing, err := os.ReadFile(path); err != nil || string(existing) != piMessagingExtensionSource {
		if err := atomicWrite(path, []byte(piMessagingExtensionSource)); err != nil {
			return fmt.Errorf("write Pi messaging extension: %w", err)
		}
	}
	return nil
}

// Uninstall implements Installer. It removes only Questmaster's extension.
func (p *PiInstaller) Uninstall() error {
	if p.agentDir() == "" {
		return errors.New("pi agent dir not resolved")
	}
	if err := os.Remove(p.extensionPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove Pi messaging extension: %w", err)
	}
	return nil
}

// Status implements Installer.
func (p *PiInstaller) Status() Report {
	if p.agentDir() == "" {
		return Report{Agent: p.Name(), Status: StatusNotInstalled, Detail: "agent dir not resolved"}
	}
	data, err := os.ReadFile(p.extensionPath())
	if errors.Is(err, os.ErrNotExist) {
		return Report{Agent: p.Name(), Status: StatusNotInstalled}
	}
	if err != nil {
		return Report{Agent: p.Name(), Status: StatusOutdated, Detail: fmt.Sprintf("extension unreadable: %v", err)}
	}
	if string(data) != piMessagingExtensionSource {
		return Report{Agent: p.Name(), Status: StatusModified, Detail: "questmaster-messaging.ts differs from shipped extension"}
	}
	return Report{Agent: p.Name(), Status: StatusCurrent}
}
