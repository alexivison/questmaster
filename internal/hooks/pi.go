package hooks

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// QuestmasterSidecarVersion is the marker version emitted by the Pi
// activity-sidecar contract that shells out to `questmaster hook pi`.
const QuestmasterSidecarVersion = "phase2-v1"

// PiInstaller manages the Pi activity-sidecar marker file. The TypeScript
// sidecar writes the same marker at runtime so `questmaster hooks status pi`
// can detect stale non-symlink installs.
type PiInstaller struct {
	// Home is the resolved Pi config directory ($PI_HOME or ~/.pi).
	// Override only in tests.
	Home string
}

// NewPiInstaller resolves $PI_HOME / $HOME.
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

// Install implements Installer. It writes the current sidecar marker
// atomically and is idempotent.
func (p *PiInstaller) Install() error {
	return p.InstallWithOptions(InstallOptions{})
}

// InstallWithOptions writes the current marker.
func (p *PiInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if p.Home == "" {
		return errors.New("pi home not resolved (set $PI_HOME or $HOME)")
	}
	if opts.DryRun {
		if existing, err := os.ReadFile(p.markerPath()); err != nil || strings.TrimSpace(string(existing)) != QuestmasterSidecarVersion {
			logf(opts, "questmaster: dry-run: would write Pi marker %s", p.markerPath())
		}
		return nil
	}
	return atomicWrite(p.markerPath(), []byte(QuestmasterSidecarVersion))
}

// Uninstall implements Installer.
func (p *PiInstaller) Uninstall() error {
	if p.Home == "" {
		return errors.New("pi home not resolved")
	}
	var firstErr error
	for _, path := range p.markerPaths() {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) && firstErr == nil {
			firstErr = err
		}
	}
	if firstErr != nil {
		return fmt.Errorf("remove pi marker: %w", firstErr)
	}
	return nil
}

// Status implements Installer.
func (p *PiInstaller) Status() Report {
	if p.Home == "" {
		return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "home dir not resolved"}
	}
	for _, path := range p.markerPaths() {
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return Report{Agent: "pi", Status: StatusOutdated, Detail: fmt.Sprintf("marker unreadable: %v", err)}
		}
		version := strings.TrimSpace(string(data))
		if version == QuestmasterSidecarVersion {
			return Report{Agent: "pi", Status: StatusCurrent}
		}
		return Report{Agent: "pi", Status: StatusOutdated, Detail: fmt.Sprintf("marker version %q != %q", version, QuestmasterSidecarVersion)}
	}
	return Report{Agent: "pi", Status: StatusNotInstalled}
}

func (p *PiInstaller) markerPath() string {
	paths := p.markerPaths()
	return paths[0]
}

func (p *PiInstaller) markerPaths() []string {
	return p.markerPathsFor(".questmaster-installed")
}

func (p *PiInstaller) markerPathsFor(name string) []string {
	agentExtensions := filepath.Join(p.Home, "agent", "extensions")
	rootExtensions := filepath.Join(p.Home, "extensions")
	if dirExists(agentExtensions) || (!dirExists(rootExtensions) && dirExists(filepath.Join(p.Home, "agent"))) {
		return []string{
			filepath.Join(agentExtensions, name),
			filepath.Join(rootExtensions, name),
		}
	}
	return []string{
		filepath.Join(rootExtensions, name),
		filepath.Join(agentExtensions, name),
	}
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
