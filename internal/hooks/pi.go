package hooks

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

//go:embed assets/questmaster-pi-messaging.ts
var piMessagingExtension string

// QuestmasterSidecarVersion is the marker version emitted by installed Pi and
// OpenCode extensions that call `questmaster hook`.
const QuestmasterSidecarVersion = "phase2-v2"

// PiInstaller manages the Pi extension marker and bundled TypeScript extension.
// The extension also refreshes the marker at runtime.
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

// Install implements Installer.
func (p *PiInstaller) Install() error {
	return p.InstallWithOptions(InstallOptions{})
}

// InstallWithOptions writes the current marker and extension.
func (p *PiInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if p.Home == "" {
		return errors.New("pi home not resolved (set $PI_HOME or $HOME)")
	}
	if warning := p.legacySidecarWarning(); warning != "" {
		logf(opts, "questmaster: warning: %s", warning)
	}
	if opts.DryRun {
		if existing, err := os.ReadFile(p.markerPath()); err != nil || strings.TrimSpace(string(existing)) != QuestmasterSidecarVersion {
			logf(opts, "questmaster: dry-run: would write Pi marker %s", p.markerPath())
		}
		return nil
	}
	if err := atomicWrite(p.markerPath(), []byte(QuestmasterSidecarVersion)); err != nil {
		return err
	}
	return atomicWrite(p.extensionPath(), []byte(piMessagingExtension))
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
	if err := os.Remove(p.extensionPath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove Pi messaging extension: %w", err)
	}
	return nil
}

// Status implements Installer.
func (p *PiInstaller) Status() Report {
	if p.Home == "" {
		return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "home dir not resolved"}
	}
	if warning := p.legacySidecarWarning(); warning != "" {
		return Report{Agent: "pi", Status: StatusOutdated, Detail: warning}
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
			extension, err := os.ReadFile(p.extensionPath())
			if err != nil || string(extension) != piMessagingExtension {
				return Report{Agent: "pi", Status: StatusOutdated, Detail: "messaging extension missing or modified"}
			}
			return Report{Agent: "pi", Status: StatusCurrent}
		}
		return Report{Agent: "pi", Status: StatusOutdated, Detail: fmt.Sprintf("marker version %q != %q", version, QuestmasterSidecarVersion)}
	}
	return Report{Agent: "pi", Status: StatusNotInstalled}
}

func (p *PiInstaller) legacySidecarWarning() string {
	var files, settings []string
	for _, path := range p.legacyExtensionPaths() {
		if _, err := os.Stat(path); err == nil {
			files = append(files, path)
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Sprintf("could not check legacy Pi sidecar %s: %v", path, err)
		}
	}
	for _, path := range p.settingsPaths() {
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return fmt.Sprintf("could not check Pi settings %s for the legacy activity sidecar: %v", path, err)
		}
		if strings.Contains(string(data), "activity-sidecar.ts") {
			settings = append(settings, path)
		}
	}
	if len(files) == 0 && len(settings) == 0 {
		return ""
	}
	locations := append(files, settings...)
	return fmt.Sprintf("legacy Pi activity sidecar detected at %s; remove the activity-sidecar.ts file and its settings.json extension reference", strings.Join(locations, ", "))
}

func (p *PiInstaller) legacyExtensionPaths() []string {
	paths := []string{
		filepath.Join(p.Home, "agent", "extensions", "activity-sidecar.ts"),
		filepath.Join(p.Home, "extensions", "activity-sidecar.ts"),
	}
	if dir := os.Getenv("PI_CODING_AGENT_DIR"); dir != "" {
		paths = append(paths, filepath.Join(dir, "extensions", "activity-sidecar.ts"))
	}
	return paths
}

func (p *PiInstaller) settingsPaths() []string {
	if dir := os.Getenv("PI_CODING_AGENT_DIR"); dir != "" {
		return []string{filepath.Join(dir, "settings.json")}
	}
	return []string{
		filepath.Join(p.Home, "agent", "settings.json"),
		filepath.Join(p.Home, "settings.json"),
	}
}

func (p *PiInstaller) extensionPath() string {
	if dir := os.Getenv("PI_CODING_AGENT_DIR"); dir != "" {
		return filepath.Join(dir, "extensions", "questmaster-messaging.ts")
	}
	return filepath.Join(p.Home, "agent", "extensions", "questmaster-messaging.ts")
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
