package config

import (
	"fmt"
	"os/exec"
	"strings"
)

// ResolveQuestmasterCmd returns the shell command string to launch questmaster.
// Standalone builds resolve only the installed binary; the former development
// go-run fallback is intentionally not part of the public module.
func ResolveQuestmasterCmd(repoRoot string) (string, error) {
	quoted := ShellQuote(repoRoot)
	if bin, err := exec.LookPath("questmaster"); err == nil {
		return fmt.Sprintf("PARTY_REPO_ROOT=%s %s", quoted, ShellQuote(bin)), nil
	}
	return "", fmt.Errorf("questmaster: not found on PATH")
}

// ShellQuote wraps a string in single quotes, escaping embedded single quotes.
func ShellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
