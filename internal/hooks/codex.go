package hooks

import (
	"errors"
	"os"
	"path/filepath"
)

// CodexInstaller is a Phase 1 stub. PR-B fills in the hooks.json merge,
// trusted_hash computation, and uninstall path. Until then Install and
// Uninstall return a sentinel error and Status reports NotInstalled.
type CodexInstaller struct {
	Home string
}

// NewCodexInstaller resolves $CODEX_HOME / $HOME for the stub. The
// resolution is included now so PR-B doesn't have to rewrite the
// constructor.
func NewCodexInstaller(home string) *CodexInstaller {
	if home == "" {
		home = os.Getenv("CODEX_HOME")
	}
	if home == "" {
		if h := os.Getenv("HOME"); h != "" {
			home = filepath.Join(h, ".codex")
		}
	}
	return &CodexInstaller{Home: home}
}

// Name implements Installer.
func (c *CodexInstaller) Name() string { return "codex" }

// Install is a stub; full implementation lands in PR-B.
func (c *CodexInstaller) Install() error {
	return errors.New("codex installer: not yet implemented — see PR-B / PR-C")
}

// Uninstall is a stub; full implementation lands in PR-B.
func (c *CodexInstaller) Uninstall() error {
	return errors.New("codex installer: not yet implemented — see PR-B / PR-C")
}

// Status returns NotInstalled until PR-B replaces this stub.
func (c *CodexInstaller) Status() Report {
	return Report{Agent: "codex", Status: StatusNotInstalled, Detail: "deferred to PR-B"}
}
