package skills

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testInstaller(t *testing.T) (*Installer, string, string) {
	t.Helper()
	home := t.TempDir()
	claude := filepath.Join(home, ".claude")
	installer, err := New(home, claude)
	if err != nil {
		t.Fatal(err)
	}
	return installer, home, claude
}

func TestInstallFreshAndRepeated(t *testing.T) {
	installer, _, _ := testInstaller(t)
	first, err := installer.Install(false)
	if err != nil {
		t.Fatalf("first install: %v", err)
	}
	if len(first) != 4 {
		t.Fatalf("reports = %d, want both skills in both destinations", len(first))
	}
	for _, report := range first {
		if report.Status != NotInstalled {
			t.Errorf("first install status = %s, want %s", report.Status, NotInstalled)
		}
	}
	for _, report := range mustStatus(t, installer) {
		if report.Status != Current {
			t.Errorf("after install status = %s for %s/%s", report.Status, report.Destination, report.Skill)
		}
		path := filepath.Join(installer.destination(report.Destination).root, report.Skill, "SKILL.md")
		body, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read %s: %v", path, err)
		}
		if len(body) == 0 {
			t.Errorf("empty bundled asset at %s", path)
		}
	}

	repeated, err := installer.Install(false)
	if err != nil {
		t.Fatalf("repeated install: %v", err)
	}
	for _, report := range repeated {
		if report.Status != Current {
			t.Errorf("repeated install status = %s, want Current", report.Status)
		}
	}
}

func TestOutdatedSkillNeedsExplicitRefresh(t *testing.T) {
	installer, home, _ := testInstaller(t)
	installer.destinations = installer.destinations[:1]
	installer.assets = []Asset{{Name: "questmaster-write-quest", Body: []byte("first version\n")}}
	if _, err := installer.Install(false); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(home, ".agents", "skills", "questmaster-write-quest", "SKILL.md")
	installer.assets[0].Body = []byte("second version\n")
	reports, err := installer.Status()
	if err != nil || len(reports) != 1 || reports[0].Status != Outdated {
		t.Fatalf("stale status = %+v, %v", reports, err)
	}
	if _, err := installer.Install(true); err != nil {
		t.Fatalf("dry-run refresh: %v", err)
	}
	assertFile(t, path, "first version\n")
	if _, err := installer.Install(false); err != nil {
		t.Fatalf("explicit refresh: %v", err)
	}
	assertFile(t, path, "second version\n")
	reports, err = installer.Status()
	if err != nil || reports[0].Status != Current {
		t.Fatalf("refreshed status = %+v, %v", reports, err)
	}
}

func TestModifiedAndCollisionContentIsPreserved(t *testing.T) {
	t.Run("modified owned copy", func(t *testing.T) {
		installer, home, _ := testInstaller(t)
		if _, err := installer.Install(false); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr", "SKILL.md")
		if err := os.WriteFile(path, []byte("user edit\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := installer.Install(false); err == nil || !strings.Contains(err.Error(), string(Modified)) {
			t.Fatalf("install error = %v, want Modified refusal", err)
		}
		assertFile(t, path, "user edit\n")
	})

	t.Run("unowned collision", func(t *testing.T) {
		installer, home, _ := testInstaller(t)
		collisionPath := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr", "SKILL.md")
		if err := os.MkdirAll(filepath.Dir(collisionPath), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(collisionPath, []byte("user skill\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if _, err := installer.Install(false); err == nil || !strings.Contains(err.Error(), string(Collision)) {
			t.Fatalf("install error = %v, want Collision refusal", err)
		}
		assertFile(t, collisionPath, "user skill\n")
	})
}

func TestInstallDoesNotPartiallyWriteAfterPreflightFailure(t *testing.T) {
	installer, home, _ := testInstaller(t)
	lastDestination := installer.destinations[1].root
	collisionDir := filepath.Join(lastDestination, installer.assets[0].Name)
	if err := os.MkdirAll(collisionDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(collisionDir, "notes.txt"), []byte("keep"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Install(false); err == nil {
		t.Fatal("install succeeded despite a collision in the final destination")
	}
	firstRoot := filepath.Join(home, ".agents", "skills")
	if _, err := os.Lstat(firstRoot); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("first destination was partially created: lstat = %v", err)
	}
	assertFile(t, filepath.Join(collisionDir, "notes.txt"), "keep")
}

func TestManagedSymlinksAreRefused(t *testing.T) {
	t.Run("skills directory", func(t *testing.T) {
		installer, _, _ := testInstaller(t)
		dest := installer.destinations[0]
		target := t.TempDir()
		if err := os.Symlink(target, dest.root); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if _, err := installer.Install(false); err == nil {
			t.Fatal("install accepted symlinked skills directory")
		}
		if _, err := os.Stat(filepath.Join(target, "questmaster-watch-pr")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("wrote through skills-directory symlink: %v", err)
		}
	})

	t.Run("skill directory", func(t *testing.T) {
		installer, home, _ := testInstaller(t)
		dest := installer.destinations[0]
		if err := os.MkdirAll(dest.root, 0o755); err != nil {
			t.Fatal(err)
		}
		target := t.TempDir()
		if err := os.WriteFile(filepath.Join(target, "keep.txt"), []byte("keep"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, filepath.Join(dest.root, "questmaster-watch-pr")); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if _, err := installer.Install(false); err == nil {
			t.Fatal("install accepted symlinked skill directory")
		}
		assertFile(t, filepath.Join(target, "keep.txt"), "keep")
		if _, err := os.Lstat(filepath.Join(home, ".agents", "skills", "questmaster-write-quest")); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("install partially wrote second skill: %v", err)
		}
	})

	t.Run("skill file", func(t *testing.T) {
		installer, home, _ := testInstaller(t)
		if _, err := installer.Install(false); err != nil {
			t.Fatal(err)
		}
		dir := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr")
		target := filepath.Join(t.TempDir(), "user-skill.md")
		if err := os.WriteFile(target, []byte("user skill\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(dir, "SKILL.md")
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, path); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if _, err := installer.Install(false); err == nil {
			t.Fatal("install accepted symlinked SKILL.md")
		}
		assertFile(t, target, "user skill\n")
	})

	t.Run("ownership record", func(t *testing.T) {
		installer, home, _ := testInstaller(t)
		if _, err := installer.Install(false); err != nil {
			t.Fatal(err)
		}
		dir := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr")
		target := filepath.Join(t.TempDir(), "owner.json")
		metadataPath := filepath.Join(dir, ownerFileName)
		data, err := os.ReadFile(metadataPath)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(target, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(metadataPath); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, metadataPath); err != nil {
			t.Skipf("symlinks unavailable: %v", err)
		}
		if _, err := installer.Uninstall(false); err == nil {
			t.Fatal("uninstall accepted symlinked ownership record")
		}
		assertFile(t, target, string(data))
		if _, err := os.Stat(filepath.Join(dir, "SKILL.md")); err != nil {
			t.Fatalf("symlink refusal removed owned skill: %v", err)
		}
	})
}

func TestParentSymlinkIsAcceptedAndResolvedPathIsShown(t *testing.T) {
	home := t.TempDir()
	physicalClaude := t.TempDir()
	physicalClaude, err := filepath.EvalSymlinks(physicalClaude)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(physicalClaude, filepath.Join(home, ".claude")); err != nil {
		t.Skipf("symlinks unavailable: %v", err)
	}
	installer, err := New(home, filepath.Join(home, ".claude"))
	if err != nil {
		t.Fatal(err)
	}
	reports, err := installer.Install(false)
	if err != nil {
		t.Fatal(err)
	}
	for _, report := range reports {
		if report.Destination != "Claude" {
			continue
		}
		if !strings.HasPrefix(report.UserPath, "~/.claude/") {
			t.Errorf("user-facing path = %q, want ~/.claude path", report.UserPath)
		}
		if !strings.HasPrefix(report.ResolvedPath, physicalClaude+string(filepath.Separator)) {
			t.Errorf("resolved path = %q, want physical config path", report.ResolvedPath)
		}
	}
}

func TestUninstallPreservesUserAddedFiles(t *testing.T) {
	installer, home, _ := testInstaller(t)
	if _, err := installer.Install(false); err != nil {
		t.Fatal(err)
	}
	userPath := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr", "notes.txt")
	if err := os.WriteFile(userPath, []byte("keep me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	reports, err := installer.Uninstall(false)
	if err != nil {
		t.Fatalf("uninstall: %v", err)
	}
	for _, report := range reports {
		if report.Status != Current {
			t.Errorf("pre-uninstall status = %s, want Current", report.Status)
		}
	}
	assertFile(t, userPath, "keep me\n")
	for _, report := range mustStatus(t, installer) {
		if report.Skill == "questmaster-watch-pr" && report.Destination == "Codex/Pi/OpenCode" {
			if report.Status != Collision {
				t.Errorf("user-owned remaining directory status = %s, want Collision", report.Status)
			}
			continue
		}
		if report.Status != NotInstalled {
			t.Errorf("after uninstall status = %s, want NotInstalled", report.Status)
		}
	}
}

func TestUninstallPreflightPreventsPartialRemoval(t *testing.T) {
	installer, home, _ := testInstaller(t)
	if _, err := installer.Install(false); err != nil {
		t.Fatal(err)
	}
	modifiedPath := filepath.Join(home, ".claude", "skills", "questmaster-write-quest", "SKILL.md")
	if err := os.WriteFile(modifiedPath, []byte("edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Uninstall(false); err == nil {
		t.Fatal("uninstall succeeded despite modified owned file")
	}
	firstPath := filepath.Join(home, ".agents", "skills", "questmaster-watch-pr", "SKILL.md")
	if _, err := os.Stat(firstPath); err != nil {
		t.Fatalf("owned file was partially removed: %v", err)
	}
	assertFile(t, modifiedPath, "edited\n")
}

func TestEmbeddedAssetsHaveNamespacedTriggerDescriptions(t *testing.T) {
	assets := Bundled()
	if len(assets) != 2 {
		t.Fatalf("embedded assets = %d, want 2", len(assets))
	}
	want := map[string]bool{"questmaster-write-quest": false, "questmaster-watch-pr": false}
	for _, asset := range assets {
		if _, ok := want[asset.Name]; !ok {
			t.Errorf("unexpected asset %q", asset.Name)
			continue
		}
		want[asset.Name] = true
		body := string(asset.Body)
		if !strings.HasPrefix(body, "---\n") || !strings.Contains(body, "name: "+asset.Name) {
			t.Errorf("%s does not have namespaced skill frontmatter", asset.Name)
		}
		description := false
		descriptionText := ""
		for _, line := range strings.Split(body, "\n") {
			if strings.HasPrefix(line, "description:") {
				description = true
				continue
			}
			if description && line != "" && !strings.HasPrefix(line, " ") {
				break
			}
			if description {
				descriptionText += line + " "
			}
		}
		if !strings.Contains(descriptionText, "Questmaster") || !strings.Contains(descriptionText, "Not for") {
			t.Errorf("%s description lacks a specific trigger boundary: %q", asset.Name, descriptionText)
		}
	}
	for name, found := range want {
		if !found {
			t.Errorf("missing embedded asset %s", name)
		}
	}
}

func TestOwnershipMetadataStoresInstalledSHA256(t *testing.T) {
	installer, home, _ := testInstaller(t)
	installer.assets = installer.assets[:1]
	installer.destinations = installer.destinations[:1]
	if _, err := installer.Install(false); err != nil {
		t.Fatal(err)
	}
	asset := installer.assets[0]
	path := filepath.Join(home, ".agents", "skills", asset.Name, ownerFileName)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var record ownerRecord
	if err := json.Unmarshal(data, &record); err != nil {
		t.Fatal(err)
	}
	if record.SHA256 != hash(asset.Body) || record.Skill != asset.Name || record.Version != 1 {
		t.Fatalf("owner record = %+v", record)
	}
}

func mustStatus(t *testing.T, installer *Installer) []Report {
	t.Helper()
	reports, err := installer.Status()
	if err != nil {
		t.Fatal(err)
	}
	return reports
}

func assertFile(t *testing.T, path, want string) {
	t.Helper()
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(body) != want {
		t.Fatalf("%s = %q, want %q", path, body, want)
	}
}
