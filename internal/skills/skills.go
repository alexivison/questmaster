// Package skills installs the bundled Questmaster agent skills into shared
// user skill directories.
package skills

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

const ownerFileName = ".questmaster-install.json"

// Asset is a bundled, instruction-only skill.
type Asset struct {
	Name string
	Body []byte
}

//go:embed assets/questmaster-*/SKILL.md
var assetFS embed.FS

var assetNames = []string{"questmaster-watch-pr", "questmaster-write-quest"}

// Bundled returns the embedded skills in stable name order.
func Bundled() []Asset {
	assets := make([]Asset, 0, len(assetNames))
	for _, name := range assetNames {
		body, err := fs.ReadFile(assetFS, "assets/"+name+"/SKILL.md")
		if err != nil {
			panic(fmt.Sprintf("read embedded skill %s: %v", name, err))
		}
		assets = append(assets, Asset{Name: name, Body: body})
	}
	return assets
}

// Status identifies the state of one skill copy in one destination.
type Status string

const (
	NotInstalled Status = "NotInstalled"
	Current      Status = "Current"
	Outdated     Status = "Outdated"
	Modified     Status = "Modified"
	Collision    Status = "Collision"
)

// Report describes one skill copy and both the path supplied by the user and
// the physical path reached after resolving parent symlinks.
type Report struct {
	Skill        string
	Destination  string
	Status       Status
	Detail       string
	UserPath     string
	ResolvedPath string
}

// Installer owns the explicitly installed skill files in its destinations.
type Installer struct {
	home         string
	destinations []destination
	assets       []Asset
}

type destination struct {
	name string
	root string
}

type ownerRecord struct {
	Version int    `json:"version"`
	Skill   string `json:"skill"`
	SHA256  string `json:"sha256"`
}

// New resolves the user skill destinations. Claude's config directory follows
// CLAUDE_CONFIG_DIR when set, then defaults to ~/.claude.
func New(home, claudeConfigDir string) (*Installer, error) {
	if home == "" {
		return nil, errors.New("home directory not resolved")
	}
	home, err := filepath.Abs(home)
	if err != nil {
		return nil, fmt.Errorf("resolve home directory: %w", err)
	}
	if claudeConfigDir == "" {
		claudeConfigDir = filepath.Join(home, ".claude")
	}
	if !filepath.IsAbs(claudeConfigDir) {
		claudeConfigDir, err = filepath.Abs(claudeConfigDir)
		if err != nil {
			return nil, fmt.Errorf("resolve Claude config directory: %w", err)
		}
	}
	return &Installer{
		home: home,
		destinations: []destination{
			{name: "Codex/Pi/OpenCode", root: filepath.Join(home, ".agents", "skills")},
			{name: "Claude", root: filepath.Join(claudeConfigDir, "skills")},
		},
		assets: Bundled(),
	}, nil
}

// NewFromEnvironment resolves HOME and CLAUDE_CONFIG_DIR from the process.
func NewFromEnvironment() (*Installer, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("resolve home directory: %w", err)
	}
	return New(home, os.Getenv("CLAUDE_CONFIG_DIR"))
}

// Status inspects every bundled skill in every managed destination.
func (i *Installer) Status() ([]Report, error) {
	return i.inspect()
}

// Install preflights every managed pair before writing. Dry-run performs the
// same preflight and returns the planned statuses without creating files.
func (i *Installer) Install(dryRun bool) ([]Report, error) {
	reports, err := i.inspect()
	if err != nil {
		return reports, err
	}
	if err := rejectUnsafe(reports); err != nil {
		return reports, err
	}
	if dryRun {
		return reports, nil
	}
	for _, report := range reports {
		if report.Status == Current {
			continue
		}
		asset := i.asset(report.Skill)
		if err := i.installOne(report, asset); err != nil {
			return reports, err
		}
	}
	return reports, nil
}

// Uninstall preflights every managed pair before removing verified owned
// files. It never recursively removes a skill directory.
func (i *Installer) Uninstall(dryRun bool) ([]Report, error) {
	reports, err := i.inspect()
	if err != nil {
		return reports, err
	}
	if err := rejectUnsafe(reports); err != nil {
		return reports, err
	}
	if dryRun {
		return reports, nil
	}
	for _, report := range reports {
		if report.Status != Current && report.Status != Outdated {
			continue
		}
		if err := i.uninstallOne(report); err != nil {
			return reports, err
		}
	}
	return reports, nil
}

func (i *Installer) inspect() ([]Report, error) {
	assets := i.assets
	reports := make([]Report, 0, len(assets)*len(i.destinations))
	for _, dest := range i.destinations {
		for _, asset := range assets {
			report, err := inspectPair(i.home, dest, asset)
			if err != nil {
				return reports, err
			}
			reports = append(reports, report)
		}
	}
	return reports, nil
}

func inspectPair(home string, dest destination, asset Asset) (Report, error) {
	dir := filepath.Join(dest.root, asset.Name)
	skillPath := filepath.Join(dir, "SKILL.md")
	report := Report{
		Skill:       asset.Name,
		Destination: dest.name,
		Status:      NotInstalled,
		UserPath:    displayPath(skillPath, home),
	}
	resolved, err := resolvePath(skillPath)
	if err != nil {
		return Report{}, fmt.Errorf("resolve %s path: %w", asset.Name, err)
	}
	absPath, err := filepath.Abs(skillPath)
	if err != nil {
		return Report{}, fmt.Errorf("resolve user-facing skill path: %w", err)
	}
	if filepath.Clean(absPath) != resolved {
		report.ResolvedPath = resolved
	}

	rootInfo, err := os.Lstat(dest.root)
	if errors.Is(err, os.ErrNotExist) {
		return report, nil
	}
	if err != nil {
		return Report{}, fmt.Errorf("inspect skills directory %s: %w", dest.root, err)
	}
	if rootInfo.Mode()&os.ModeSymlink != 0 {
		report.Status, report.Detail = Collision, "skills directory is a symlink"
		return report, nil
	}
	if !rootInfo.IsDir() {
		report.Status, report.Detail = Collision, "skills destination is not a directory"
		return report, nil
	}

	dirInfo, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return report, nil
	}
	if err != nil {
		return Report{}, fmt.Errorf("inspect managed skill directory %s: %w", dir, err)
	}
	if dirInfo.Mode()&os.ModeSymlink != 0 {
		report.Status, report.Detail = Collision, "managed skill directory is a symlink"
		return report, nil
	}
	if !dirInfo.IsDir() {
		report.Status, report.Detail = Collision, "managed skill path is not a directory"
		return report, nil
	}

	metadataPath := filepath.Join(dir, ownerFileName)
	metadataInfo, err := os.Lstat(metadataPath)
	if errors.Is(err, os.ErrNotExist) {
		report.Status, report.Detail = Collision, "directory has no Questmaster ownership record"
		return report, nil
	}
	if err != nil {
		return Report{}, fmt.Errorf("inspect ownership record %s: %w", metadataPath, err)
	}
	if metadataInfo.Mode()&os.ModeSymlink != 0 {
		report.Status, report.Detail = Collision, "ownership record is a symlink"
		return report, nil
	}
	if !metadataInfo.Mode().IsRegular() {
		report.Status, report.Detail = Collision, "ownership record is not a regular file"
		return report, nil
	}
	metadata, err := os.ReadFile(metadataPath)
	if err != nil {
		return Report{}, fmt.Errorf("read ownership record %s: %w", metadataPath, err)
	}
	var record ownerRecord
	if err := json.Unmarshal(metadata, &record); err != nil || record.Version != 1 || record.Skill != asset.Name || !validHash(record.SHA256) {
		report.Status, report.Detail = Collision, "ownership record is invalid or belongs to another skill"
		return report, nil
	}

	fileInfo, err := os.Lstat(skillPath)
	if errors.Is(err, os.ErrNotExist) {
		report.Status, report.Detail = Modified, "owned SKILL.md is missing"
		return report, nil
	}
	if err != nil {
		return Report{}, fmt.Errorf("inspect owned skill file %s: %w", skillPath, err)
	}
	if fileInfo.Mode()&os.ModeSymlink != 0 {
		report.Status, report.Detail = Collision, "managed SKILL.md is a symlink"
		return report, nil
	}
	if !fileInfo.Mode().IsRegular() {
		report.Status, report.Detail = Collision, "managed SKILL.md is not a regular file"
		return report, nil
	}
	body, err := os.ReadFile(skillPath)
	if err != nil {
		return Report{}, fmt.Errorf("read owned skill file %s: %w", skillPath, err)
	}
	if hash(body) != record.SHA256 {
		report.Status, report.Detail = Modified, "installed file differs from its ownership record"
		return report, nil
	}
	if hash(asset.Body) != record.SHA256 {
		report.Status, report.Detail = Outdated, "bundled skill has changed"
		return report, nil
	}
	report.Status = Current
	return report, nil
}

func rejectUnsafe(reports []Report) error {
	for _, report := range reports {
		if report.Status == Collision || report.Status == Modified {
			return fmt.Errorf("refusing skills operation: %s at %s: %s", report.Status, report.UserPath, report.Detail)
		}
	}
	return nil
}

func (i *Installer) installOne(report Report, asset Asset) error {
	dest := i.destination(report.Destination)
	dir := filepath.Join(dest.root, report.Skill)
	if err := ensureDirectory(dest.root, 0o755); err != nil {
		return fmt.Errorf("create skills directory %s: %w", dest.root, err)
	}
	if report.Status == NotInstalled {
		if err := os.Mkdir(dir, 0o755); err != nil {
			return fmt.Errorf("create managed skill directory %s: %w", dir, err)
		}
	} else {
		info, err := os.Lstat(dir)
		if err != nil {
			return fmt.Errorf("inspect managed skill directory %s: %w", dir, err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return fmt.Errorf("refusing managed skill directory that is not a real directory: %s", dir)
		}
		if err := verifyOwnedCopy(filepath.Join(dir, "SKILL.md"), filepath.Join(dir, ownerFileName), report.Skill); err != nil {
			return fmt.Errorf("verify existing skill %s at %s: %w", report.Skill, dir, err)
		}
	}
	if err := writeOwnedFile(filepath.Join(dir, "SKILL.md"), asset.Body, 0o644, report.Status == Outdated); err != nil {
		return fmt.Errorf("install %s at %s: %w", report.Skill, dir, err)
	}
	metadata, err := json.Marshal(ownerRecord{Version: 1, Skill: report.Skill, SHA256: hash(asset.Body)})
	if err != nil {
		return fmt.Errorf("encode ownership record for %s: %w", report.Skill, err)
	}
	metadata = append(metadata, '\n')
	if err := writeOwnedFile(filepath.Join(dir, ownerFileName), metadata, 0o600, report.Status == Outdated); err != nil {
		return fmt.Errorf("record ownership for %s at %s: %w", report.Skill, dir, err)
	}
	return nil
}

func (i *Installer) uninstallOne(report Report) error {
	dir := filepath.Join(i.destination(report.Destination).root, report.Skill)
	filePath := filepath.Join(dir, "SKILL.md")
	metadataPath := filepath.Join(dir, ownerFileName)
	if err := verifyOwnedCopy(filePath, metadataPath, report.Skill); err != nil {
		return fmt.Errorf("uninstall %s at %s: %w", report.Skill, report.UserPath, err)
	}
	if err := os.Remove(filePath); err != nil {
		return fmt.Errorf("remove %s: %w", filePath, err)
	}
	if err := os.Remove(metadataPath); err != nil {
		return fmt.Errorf("remove ownership record %s: %w", metadataPath, err)
	}
	// User-added files keep their containing skill directory in place.
	if err := os.Remove(dir); err != nil && !errors.Is(err, os.ErrNotExist) && !errors.Is(err, syscall.ENOTEMPTY) {
		return fmt.Errorf("remove empty skill directory %s: %w", dir, err)
	}
	return nil
}

func verifyOwnedCopy(filePath, metadataPath, skill string) error {
	for _, path := range []string{filePath, metadataPath} {
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("managed path is not a regular file: %s", path)
		}
	}
	data, err := os.ReadFile(metadataPath)
	if err != nil {
		return err
	}
	var record ownerRecord
	if err := json.Unmarshal(data, &record); err != nil || record.Version != 1 || record.Skill != skill || !validHash(record.SHA256) {
		return errors.New("ownership record is invalid")
	}
	body, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	if hash(body) != record.SHA256 {
		return errors.New("installed file was modified")
	}
	return nil
}

func writeOwnedFile(path string, data []byte, mode os.FileMode, replace bool) error {
	if info, err := os.Lstat(path); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() {
			return fmt.Errorf("refusing non-regular managed file %s", path)
		}
		if !replace {
			return fmt.Errorf("refusing to replace existing unowned file %s", path)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	dir := filepath.Dir(path)
	temp, err := os.CreateTemp(dir, ".questmaster-write-*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err := temp.Chmod(mode); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if replace {
		if err := os.Rename(tempPath, path); err != nil {
			return err
		}
	} else {
		if err := os.Link(tempPath, path); err != nil {
			return err
		}
	}
	return nil
}

func ensureDirectory(path string, mode os.FileMode) error {
	if err := os.MkdirAll(path, mode); err != nil {
		return err
	}
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("refusing managed directory that is not a real directory: %s", path)
	}
	return nil
}

func (i *Installer) asset(name string) Asset {
	for _, asset := range i.assets {
		if asset.Name == name {
			return asset
		}
	}
	panic("missing bundled skill " + name)
}

func (i *Installer) destination(name string) destination {
	for _, dest := range i.destinations {
		if dest.name == name {
			return dest
		}
	}
	panic("missing skill destination " + name)
}

func hash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func validHash(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func displayPath(path, home string) string {
	path = filepath.Clean(path)
	rel, err := filepath.Rel(home, path)
	if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		if rel == "." {
			return "~"
		}
		return filepath.Join("~", rel)
	}
	return path
}

// resolvePath resolves symlinks in the existing prefix and appends any missing
// suffix. It intentionally does not require the final skill file to exist.
func resolvePath(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	current := filepath.Clean(abs)
	var suffix []string
	for {
		_, err := os.Lstat(current)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		parent := filepath.Dir(current)
		if parent == current {
			break
		}
		suffix = append(suffix, filepath.Base(current))
		current = parent
	}
	resolved, err := filepath.EvalSymlinks(current)
	if err != nil {
		return "", err
	}
	for n := len(suffix) - 1; n >= 0; n-- {
		resolved = filepath.Join(resolved, suffix[n])
	}
	return filepath.Clean(resolved), nil
}
