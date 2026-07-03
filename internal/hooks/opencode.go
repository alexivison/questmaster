package hooks

import (
	_ "embed"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	qmagent "github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

//go:embed assets/opencode-questmaster-plugin.js
var openCodePluginSource string

const (
	openCodePluginFileName = "questmaster-opencode.js"
)

// OpenCodeInstaller manages Questmaster's OpenCode plugin bridge and role
// agents. It writes only Questmaster-owned files under Questmaster's private
// OpenCode config dir.
type OpenCodeInstaller struct {
	// ConfigDir is the Questmaster-owned OpenCode config directory. Override in tests.
	ConfigDir string
}

// NewOpenCodeInstaller resolves Questmaster's OpenCode config directory. Pass
// an explicit dir for tests; pass "" to use <QUESTMASTER_STATE_ROOT>/opencode.
func NewOpenCodeInstaller(configDir string) *OpenCodeInstaller {
	if configDir == "" {
		configDir = state.OpenCodeConfigDir(state.StateRoot())
	}
	return &OpenCodeInstaller{ConfigDir: configDir}
}

// Name implements Installer.
func (o *OpenCodeInstaller) Name() string { return "opencode" }

func (o *OpenCodeInstaller) pluginPath() string {
	return filepath.Join(o.ConfigDir, "plugins", openCodePluginFileName)
}

func (o *OpenCodeInstaller) agentPath(name string) string {
	return filepath.Join(o.ConfigDir, "agents", name+".md")
}

func (o *OpenCodeInstaller) managedFiles() []openCodeManagedFile {
	return openCodeManagedFiles(o.ConfigDir)
}

// Install implements Installer.
func (o *OpenCodeInstaller) Install() error { return o.InstallWithOptions(InstallOptions{}) }

// InstallWithOptions writes the plugin bridge and role agent files. It is
// content-idempotent and preserves all other user-managed OpenCode config.
func (o *OpenCodeInstaller) InstallWithOptions(opts InstallOptions) error {
	opts = opts.normalized()
	if o.ConfigDir == "" {
		return errors.New("OpenCode config dir not resolved (set QUESTMASTER_STATE_ROOT or HOME)")
	}
	for _, file := range o.managedFiles() {
		if existing, err := os.ReadFile(file.Path); err == nil && string(existing) == file.Body {
			continue
		}
		if opts.DryRun {
			logf(opts, "questmaster: dry-run: would write OpenCode %s %s", file.Kind, file.Path)
			continue
		}
		if err := atomicWrite(file.Path, []byte(file.Body)); err != nil {
			return fmt.Errorf("write %s: %w", file.Path, err)
		}
	}
	return nil
}

// Uninstall implements Installer. Removes only Questmaster-owned OpenCode
// plugin/agent files and leaves all other user config alone.
func (o *OpenCodeInstaller) Uninstall() error {
	if o.ConfigDir == "" {
		return errors.New("OpenCode config dir not resolved")
	}
	for _, file := range o.managedFiles() {
		if err := os.Remove(file.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove %s: %w", file.Path, err)
		}
	}
	return nil
}

// Status implements Installer.
func (o *OpenCodeInstaller) Status() Report {
	if o.ConfigDir == "" {
		return Report{Agent: o.Name(), Status: StatusNotInstalled, Detail: "config dir not resolved"}
	}
	files := o.managedFiles()
	present := 0
	for _, file := range files {
		data, err := os.ReadFile(file.Path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return Report{Agent: o.Name(), Status: StatusOutdated, Detail: fmt.Sprintf("%s unreadable: %v", file.Path, err)}
		}
		present++
		if string(data) != file.Body {
			return Report{Agent: o.Name(), Status: StatusModified, Detail: fmt.Sprintf("%s differs from shipped %s", filepath.Base(file.Path), file.Kind)}
		}
	}
	if present == 0 {
		return Report{Agent: o.Name(), Status: StatusNotInstalled}
	}
	if present != len(files) {
		return Report{Agent: o.Name(), Status: StatusModified, Detail: "one or more managed OpenCode files are missing"}
	}
	return Report{Agent: o.Name(), Status: StatusCurrent}
}

type openCodeManagedFile struct {
	Path string
	Body string
	Kind string
}

func openCodeManagedFiles(configDir string) []openCodeManagedFile {
	provider := qmagent.NewOpenCode(qmagent.AgentConfig{})
	return []openCodeManagedFile{
		{
			Path: filepath.Join(configDir, "plugins", openCodePluginFileName),
			Body: openCodePluginSource,
			Kind: "plugin",
		},
		{
			Path: filepath.Join(configDir, "agents", qmagent.OpenCodeMasterAgentName+".md"),
			Body: openCodeAgentMarkdown(
				"Questmaster master orchestrator session",
				provider.MasterPrompt(),
			),
			Kind: "agent",
		},
		{
			Path: filepath.Join(configDir, "agents", qmagent.OpenCodeStandaloneAgentName+".md"),
			Body: openCodeAgentMarkdown(
				"Questmaster standalone session",
				provider.StandalonePrompt(),
			),
			Kind: "agent",
		},
		{
			Path: filepath.Join(configDir, "agents", qmagent.OpenCodeWorkerAgentName+".md"),
			Body: openCodeAgentMarkdown("Questmaster worker session", provider.WorkerPrompt()),
			Kind: "agent",
		},
	}
}

func openCodeAgentMarkdown(description, prompt string) string {
	var b strings.Builder
	b.WriteString("---\n")
	fmt.Fprintf(&b, "description: %s\n", description)
	b.WriteString("mode: primary\n")
	b.WriteString("permission:\n")
	b.WriteString("  \"*\": allow\n")
	b.WriteString("  external_directory:\n")
	b.WriteString("    \"*\": allow\n")
	b.WriteString("  doom_loop: allow\n")
	b.WriteString("---\n\n")
	b.WriteString(strings.TrimSpace(prompt))
	b.WriteByte('\n')
	return b.String()
}
