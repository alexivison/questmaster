// Package hooks installs and uninstalls the per-agent shell hooks that
// drive party-cli's state tracker. Each Installer knows how to render the
// dumb shell script, write it to the agent's config directory, and merge
// its hook entries into the agent-native config file with a `_party_cli`
// tag for safe round-trip uninstall.
package hooks

import (
	_ "embed"
	"fmt"
	"sort"
	"strings"
)

// AssetTag is the tag value written into agent config files alongside
// hook entries we own. The tag identifies entries the installer is
// allowed to remove on uninstall. Bumping this value requires reviewing
// the round-trip behaviour for every agent's config format.
const AssetTag = "v1"

// ScriptTemplate is the embedded shell-script body. The `__AGENT__`
// placeholder is substituted with the agent name at install time.
//
//go:embed assets/party-cli-state.sh
var ScriptTemplate string

// Status enumerates the per-agent installation states reported by
// `party-cli hooks status`. The set mirrors PLAN.md "Status per agent"
// (lines 214–220).
type Status string

const (
	StatusCurrent      Status = "Current"
	StatusOutdated     Status = "Outdated"
	StatusUntrusted    Status = "Untrusted"
	StatusModified     Status = "Modified"
	StatusNotInstalled Status = "NotInstalled"
)

// Report is the per-agent status row.
type Report struct {
	Agent  string
	Status Status
	Detail string
}

// Installer is the per-agent contract. Implementations are registered
// with Manager via RegisterDefault.
type Installer interface {
	// Name is the agent identifier ("claude", "codex", "pi") used in CLI
	// arguments and the hook payload command.
	Name() string
	// Install writes/updates hooks on disk. Idempotent: re-running must
	// produce a byte-identical config file when nothing changed.
	Install() error
	// Uninstall removes only the entries the installer owns (tagged with
	// `_party_cli: v1`) and deletes the installed script file. Leaves
	// other user-managed hooks alone.
	Uninstall() error
	// Status reports the current install state. Never returns an error;
	// installer-internal problems surface in Report.Detail.
	Status() Report
}

// Manager orchestrates a fixed set of installers.
type Manager struct {
	installers map[string]Installer
	order      []string
}

// NewManager returns a Manager seeded with the built-in installers.
func NewManager() *Manager {
	m := &Manager{installers: map[string]Installer{}}
	for _, inst := range []Installer{
		NewClaudeInstaller(""),
		NewCodexInstaller(""),
		NewPiInstaller(""),
	} {
		m.Register(inst)
	}
	return m
}

// Register adds an installer to the manager. Used by tests to inject
// stub installers rooted at temp directories.
func (m *Manager) Register(inst Installer) {
	if _, ok := m.installers[inst.Name()]; !ok {
		m.order = append(m.order, inst.Name())
	}
	m.installers[inst.Name()] = inst
	sort.Strings(m.order)
}

// Names returns the registered agent names in stable order.
func (m *Manager) Names() []string {
	out := make([]string, len(m.order))
	copy(out, m.order)
	return out
}

// Resolve returns the installer for the named agent.
func (m *Manager) Resolve(name string) (Installer, error) {
	inst, ok := m.installers[name]
	if !ok {
		return nil, fmt.Errorf("unknown agent %q (known: %s)", name, strings.Join(m.Names(), ", "))
	}
	return inst, nil
}

// Install runs Install for the named agents (or all if empty).
func (m *Manager) Install(agents []string) error {
	for _, name := range m.selection(agents) {
		inst, err := m.Resolve(name)
		if err != nil {
			return err
		}
		if err := inst.Install(); err != nil {
			return fmt.Errorf("%s install: %w", name, err)
		}
	}
	return nil
}

// Uninstall runs Uninstall for the named agents (or all if empty).
func (m *Manager) Uninstall(agents []string) error {
	for _, name := range m.selection(agents) {
		inst, err := m.Resolve(name)
		if err != nil {
			return err
		}
		if err := inst.Uninstall(); err != nil {
			return fmt.Errorf("%s uninstall: %w", name, err)
		}
	}
	return nil
}

// Status returns one Report per requested agent (or all if empty).
func (m *Manager) Status(agents []string) ([]Report, error) {
	names := m.selection(agents)
	out := make([]Report, 0, len(names))
	for _, name := range names {
		inst, err := m.Resolve(name)
		if err != nil {
			return nil, err
		}
		out = append(out, inst.Status())
	}
	return out, nil
}

// CheckCurrent returns false if any selected agent isn't Current. Used
// by `hooks install --check`.
func (m *Manager) CheckCurrent(agents []string) (bool, []Report, error) {
	reports, err := m.Status(agents)
	if err != nil {
		return false, nil, err
	}
	for _, r := range reports {
		if r.Status != StatusCurrent {
			return false, reports, nil
		}
	}
	return true, reports, nil
}

func (m *Manager) selection(agents []string) []string {
	if len(agents) == 0 {
		return m.Names()
	}
	out := make([]string, 0, len(agents))
	for _, a := range agents {
		out = append(out, a)
	}
	return out
}

// RenderScript fills the embedded template for a given agent. Exposed
// for installer implementations (and tests).
func RenderScript(agent string) string {
	return strings.ReplaceAll(ScriptTemplate, "__AGENT__", agent)
}
