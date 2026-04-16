package config

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// ResolvePartyCLICmd returns the shell command string to launch party-cli.
// Resolution order: installed binary on PATH first, then go run as fallback.
// Resolution order mirrors session/party.sh: installed binary first, go run fallback.
func ResolvePartyCLICmd(repoRoot string) (string, error) {
	quoted := ShellQuote(repoRoot)

	if bin, err := exec.LookPath("party-cli"); err == nil {
		return fmt.Sprintf("PARTY_REPO_ROOT=%s %s", quoted, ShellQuote(bin)), nil
	}

	if _, err := exec.LookPath("go"); err == nil {
		mainGo := filepath.Join(repoRoot, "tools", "party-cli", "main.go")
		if _, err := os.Stat(mainGo); err == nil {
			// Run from within the module directory so go.mod is found.
			modDir := ShellQuote(filepath.Join(repoRoot, "tools", "party-cli"))
			return fmt.Sprintf("cd %s && PARTY_REPO_ROOT=%s go run .", modDir, quoted), nil
		}
		return "", fmt.Errorf("party-cli: Go available but %s not found", mainGo)
	}

	return "", fmt.Errorf("party-cli: not found on PATH and Go toolchain unavailable")
}

// ShellQuote wraps a string in single quotes, escaping embedded single quotes.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
