package tmuxconfig_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestThemeStatusWidgetUsesSuppliedColours(t *testing.T) {
	root := t.TempDir()
	if err := prepareConfig(t, root); err != nil {
		t.Fatal(err)
	}
	repo := t.TempDir()
	cmd := exec.Command("git", "-C", repo, "init", "-b", "sample")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git init: %v: %s", err, output)
	}
	cmd = exec.Command("git", "-C", repo, "-c", "user.name=Example", "-c", "user.email=dev@example.com", "commit", "--allow-empty", "-m", "Sample")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git commit: %v: %s", err, output)
	}
	if err := os.WriteFile(filepath.Join(repo, "sample.txt"), []byte("sample\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(filepath.Dir(tmuxconfig.Paths(root).Theme), "theme-git-status.sh")
	// A branch and an untracked file render the first and last colour args.
	cmd = exec.Command("bash", script, repo, palette.Display("violet"), palette.Display("yellow"), palette.Display("green"), palette.Display("red"), palette.Display("cyan"))
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("status script: %v: %s", err, output)
	}
	for _, color := range []string{"violet", "cyan"} {
		if !strings.Contains(string(output), "fg="+palette.Display(color)) {
			t.Errorf("status %q does not use %s", output, color)
		}
	}
}
