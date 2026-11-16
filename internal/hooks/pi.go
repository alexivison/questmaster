package hooks

import (
	"bytes"
	_ "embed"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

//go:embed assets/questmaster-pi-messaging.ts
var piMessagingExtension string

const (
	// piLegacyExtensionName is the copy older installers wrote into Pi's
	// extensions dir. The owned extension lives under the state root instead.
	piLegacyExtensionName = "questmaster-messaging.ts"
	// piLegacyMarkerName is the marker older installers wrote beside it.
	piLegacyMarkerName = ".questmaster-installed"
	// piLegacyMaxBytes bounds the read that identifies a legacy file. Copies
	// are tens of KiB.
	piLegacyMaxBytes = 1 << 20
)

// piLegacyMarker matches the version markers older installers wrote.
var piLegacyMarker = regexp.MustCompile(`^phase\d+-v\d+$`)

// PiInstaller writes the Questmaster-owned Pi extension under the state root
// and retires the copies older installers wrote into Pi's extensions dirs.
type PiInstaller struct {
	// Home is the resolved Pi config directory ($PI_HOME or ~/.pi), searched for
	// legacy copies. Override only in tests.
	Home string
	// ExtensionDir is the Questmaster-owned directory the extension is written
	// to, state.PiExtensionDir of the state root. Pi loads the file with -e.
	ExtensionDir string
}

// NewPiInstaller resolves $PI_HOME / $HOME and the state root.
func NewPiInstaller(home string) *PiInstaller {
	if home == "" {
		home = os.Getenv("PI_HOME")
	}
	if home == "" {
		if h := os.Getenv("HOME"); h != "" {
			home = filepath.Join(h, ".pi")
		}
	}
	return &PiInstaller{Home: home, ExtensionDir: state.PiExtensionDir(state.StateRoot())}
}

// Name implements Installer.
func (p *PiInstaller) Name() string { return "pi" }

// Install implements Installer.
func (p *PiInstaller) Install() error {
	return p.InstallWithOptions(InstallOptions{})
}

// InstallWithOptions retires legacy copies and writes the owned extension. A
// recognized legacy extension symlink blocks installation because Pi loads it
// alongside the owned extension. The owned file is left untouched when it
// already holds the bundled asset.
func (p *PiInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if p.Home == "" {
		return errors.New("pi home not resolved (set $PI_HOME or $HOME)")
	}
	if p.ExtensionDir == "" {
		return errors.New("pi extension dir not resolved (state root is unset)")
	}
	legacyFiles := p.legacyFiles()
	if path := legacyExtensionSymlinkPath(legacyFiles); path != "" {
		conflict := legacyExtensionLinkConflict(path)
		if opts.DryRun {
			logf(opts, "questmaster: dry-run: install blocked: %s", conflict)
			return nil
		}
		return conflict
	}
	if warning := p.legacySidecarWarning(); warning != "" {
		logf(opts, "questmaster: warning: %s", warning)
	}
	for _, legacy := range legacyFiles {
		switch {
		case legacy.link:
			logf(opts, "questmaster: warning: legacy Questmaster Pi link at %s is left in place; remove it by hand", legacy.path)
		case opts.DryRun:
			logf(opts, "questmaster: dry-run: would remove legacy Pi file %s", legacy.path)
		default:
			if err := os.Remove(legacy.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
				return fmt.Errorf("remove legacy Pi file: %w", err)
			}
			logf(opts, "questmaster: removed legacy Pi file %s", legacy.path)
		}
	}
	if p.ownedExtensionCurrent() {
		return nil
	}
	if opts.DryRun {
		logf(opts, "questmaster: dry-run: would write Pi extension %s", p.extensionFile())
		return nil
	}
	if err := os.MkdirAll(p.ExtensionDir, 0o700); err != nil {
		return err
	}
	return atomicWriteMode(p.extensionFile(), []byte(piMessagingExtension), 0o600)
}

// Uninstall implements Installer. It retires legacy copies, leaving symlinks in
// place, and removes the owned extension.
func (p *PiInstaller) Uninstall() error {
	if p.Home == "" {
		return errors.New("pi home not resolved")
	}
	for _, legacy := range p.legacyFiles() {
		if legacy.link {
			continue
		}
		if err := os.Remove(legacy.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("remove legacy Pi file: %w", err)
		}
	}
	if p.ExtensionDir == "" {
		return nil
	}
	if err := os.Remove(p.extensionFile()); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("remove Pi extension: %w", err)
	}
	return nil
}

// CheckLegacyExtensionSymlink reports whether Pi would auto-discover a
// recognized legacy messaging extension symlink beside the owned extension.
func (p *PiInstaller) CheckLegacyExtensionSymlink() error {
	if p.Home == "" {
		return errors.New("pi home not resolved (set $PI_HOME or $HOME)")
	}
	if path := legacyExtensionSymlinkPath(p.legacyFiles()); path != "" {
		return legacyExtensionLinkConflict(path)
	}
	return nil
}

func legacyExtensionLinkConflict(path string) error {
	return fmt.Errorf("legacy Questmaster Pi messaging extension symlink at %s is auto-discovered alongside the owned extension; remove the symlink (its target will be left untouched) before installing or launching Pi", path)
}

func legacyExtensionSymlinkPath(legacy []piLegacyFile) string {
	for _, f := range legacy {
		if f.link && filepath.Base(f.path) == piLegacyExtensionName {
			return f.path
		}
	}
	return ""
}

// Status implements Installer.
func (p *PiInstaller) Status() Report {
	if p.Home == "" {
		return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "home dir not resolved"}
	}
	if warning := p.legacySidecarWarning(); warning != "" {
		return Report{Agent: "pi", Status: StatusOutdated, Detail: warning}
	}
	if legacy := p.legacyFiles(); len(legacy) > 0 {
		return Report{Agent: "pi", Status: StatusOutdated, Detail: legacyDetail(legacy)}
	}
	if p.ExtensionDir == "" {
		return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "state root not resolved"}
	}
	path := p.extensionFile()
	data, err := os.ReadFile(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return Report{Agent: "pi", Status: StatusNotInstalled, Detail: "written at the next Pi launch"}
	case err != nil:
		return Report{Agent: "pi", Status: StatusOutdated, Detail: fmt.Sprintf("Pi extension at %s is unreadable: %v", path, err)}
	case string(data) != piMessagingExtension:
		return Report{Agent: "pi", Status: StatusOutdated, Detail: fmt.Sprintf("Pi extension at %s is out of date; the next Pi launch or hooks install rewrites it", path)}
	}
	return Report{Agent: "pi", Status: StatusCurrent}
}

// extensionFile is the Questmaster-owned extension file. Callers check that
// ExtensionDir is set first.
func (p *PiInstaller) extensionFile() string {
	return filepath.Join(p.ExtensionDir, state.PiExtensionFileName)
}

// ownedExtensionCurrent reports whether the owned extension already holds the
// bundled asset.
func (p *PiInstaller) ownedExtensionCurrent() bool {
	if p.ExtensionDir == "" {
		return false
	}
	data, err := os.ReadFile(p.extensionFile())
	return err == nil && string(data) == piMessagingExtension
}

// piLegacyFile is a Questmaster file an older installer left in a Pi
// extensions dir.
type piLegacyFile struct {
	path string
	// link marks a symlink. It is reported but never removed, since it may point
	// at a copy the user manages.
	link bool
}

// legacyFiles returns the older Questmaster files in Pi's extensions dirs. A
// file counts only when its content carries the marks an older installer wrote,
// so a user's own file with the same name is left alone.
func (p *PiInstaller) legacyFiles() []piLegacyFile {
	var found []piLegacyFile
	for _, dir := range p.legacyExtensionDirs() {
		if f, ok := inspectLegacyFile(filepath.Join(dir, piLegacyExtensionName), isLegacyExtension); ok {
			found = append(found, f)
		}
		if f, ok := inspectLegacyFile(filepath.Join(dir, piLegacyMarkerName), isLegacyMarker); ok {
			found = append(found, f)
		}
	}
	return found
}

// legacyExtensionDirs lists the Pi extensions dirs older installers may have
// written to. The marker was always written under Home, even when
// PI_CODING_AGENT_DIR moved the extension, so both places are searched.
func (p *PiInstaller) legacyExtensionDirs() []string {
	var candidates []string
	if dir := os.Getenv("PI_CODING_AGENT_DIR"); dir != "" {
		candidates = append(candidates, filepath.Join(dir, "extensions"))
	}
	if p.Home != "" {
		candidates = append(candidates, filepath.Join(p.Home, "agent", "extensions"), filepath.Join(p.Home, "extensions"))
	}
	var dirs []string
	for _, dir := range candidates {
		if !slices.Contains(dirs, dir) {
			dirs = append(dirs, dir)
		}
	}
	return dirs
}

// inspectLegacyFile reports whether path is an older Questmaster file. A symlink
// is followed only to read it, and the link itself is never removed.
func inspectLegacyFile(path string, match func([]byte) bool) (piLegacyFile, bool) {
	info, err := os.Lstat(path)
	if err != nil {
		return piLegacyFile{}, false
	}
	link := info.Mode()&fs.ModeSymlink != 0
	if link {
		if info, err = os.Stat(path); err != nil {
			return piLegacyFile{}, false
		}
	}
	if !info.Mode().IsRegular() || info.Size() > piLegacyMaxBytes {
		return piLegacyFile{}, false
	}
	data, err := os.ReadFile(path)
	if err != nil || !match(data) {
		return piLegacyFile{}, false
	}
	return piLegacyFile{path: path, link: link}, true
}

// isLegacyExtension reports whether content is an older copy of the messaging
// extension. Every version Questmaster has shipped reads QUESTMASTER_SESSION, the
// session's own variable, including the messaging-only copy that predates the
// hook calls. A user's file of the same name would not normally read it.
func isLegacyExtension(data []byte) bool {
	return bytes.Contains(data, []byte("process.env.QUESTMASTER_SESSION"))
}

// isLegacyMarker reports whether content is an older installer's version marker.
func isLegacyMarker(data []byte) bool {
	return piLegacyMarker.Match(bytes.TrimSpace(data))
}

// legacyDetail names the legacy files Status found. Regular files are removed by
// hooks install; symlinks are left for the user.
func legacyDetail(legacy []piLegacyFile) string {
	var removable, links []string
	for _, f := range legacy {
		if f.link {
			links = append(links, f.path)
		} else {
			removable = append(removable, f.path)
		}
	}
	var parts []string
	if len(removable) > 0 {
		parts = append(parts, fmt.Sprintf("legacy Questmaster Pi files at %s; run questmaster hooks install pi to remove it", strings.Join(removable, ", ")))
	}
	if len(links) > 0 {
		parts = append(parts, fmt.Sprintf("legacy Questmaster Pi links at %s are left in place; remove them by hand", strings.Join(links, ", ")))
	}
	return strings.Join(parts, "; ")
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
