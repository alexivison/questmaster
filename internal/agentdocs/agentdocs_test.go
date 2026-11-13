// Package agentdocs holds guardrail tests for the agent-facing documentation:
// the root AGENTS.md and the project skills under .agents/skills. It has no
// production code. The tests check structure (size, pointers, frontmatter,
// symlinks), not whether the prose is true.
package agentdocs

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

const (
	// rootMaxBytes keeps a future edit from pushing Codex past its 32 KiB
	// project-doc cap once the user's global file is counted first.
	rootMaxBytes = 20 * 1024

	skillsDir       = ".agents/skills"
	claudeSkillsDir = ".claude/skills"

	// agentskills.io limits; Claude Code's own limit (description plus
	// when_to_use, 1,536 characters) is looser, so these are the binding ones.
	skillNameMax        = 64
	skillDescriptionMax = 1024
	skillBodyMaxLines   = 500
)

// damagePreventingPhrases must stay in the root file: each guards a rule whose
// absence causes real damage and that must never sit only inside a skill.
var damagePreventingPhrases = []string{
	"-buildvcs=false",
	"build-app.sh",
	"install-app.sh",
	"osascript",
	"origin/main",
	"SessionTarget",
	"QUESTMASTER_BIN",
}

var (
	skillNameRE = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	// backtick-quoted tokens that look like repo paths into the skills tree.
	skillPathRE = regexp.MustCompile("`(\\.agents/skills/[^`\\s]+\\.md)`")
	// backtick-quoted relative references inside a SKILL.md.
	referencePathRE = regexp.MustCompile("`(references/[^`\\s]+)`")
	// any .agents/skills path in Swift sources, tests included.
	swiftSkillPathRE = regexp.MustCompile(`\.agents/skills/[A-Za-z0-9._/-]+\.md`)
)

func repoRoot(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("go.mod not found above the test directory")
		}
		dir = parent
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func skillNames(t *testing.T, root string) []string {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(root, skillsDir))
	if err != nil {
		t.Fatalf("read %s: %v", skillsDir, err)
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() {
			names = append(names, e.Name())
		}
	}
	if len(names) == 0 {
		t.Fatalf("no skills under %s", skillsDir)
	}
	sort.Strings(names)
	return names
}

func TestRootFileIsASmallRealFile(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	info, err := os.Stat(filepath.Join(root, "AGENTS.md"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Size() > rootMaxBytes {
		t.Errorf("AGENTS.md is %d bytes, over the %d byte cap: move detail into a skill", info.Size(), rootMaxBytes)
	}
	link, err := os.Readlink(filepath.Join(root, "CLAUDE.md"))
	if err != nil || link != "AGENTS.md" {
		t.Errorf("CLAUDE.md must be a symlink to AGENTS.md, got target %q (err %v)", link, err)
	}
}

func TestRootKeepsDamagePreventingRules(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	text := readFile(t, filepath.Join(root, "AGENTS.md"))
	for _, phrase := range damagePreventingPhrases {
		if !strings.Contains(text, phrase) {
			t.Errorf("AGENTS.md no longer mentions %q: that rule must stay in the always-loaded root", phrase)
		}
	}
}

func TestRootPointersResolveAndEverySkillIsIndexed(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	text := readFile(t, filepath.Join(root, "AGENTS.md"))
	// The pending-skill comment is a placeholder, not a pointer.
	live := regexp.MustCompile(`(?s)<!--.*?-->`).ReplaceAllString(text, "")

	pointed := map[string]bool{}
	for _, m := range skillPathRE.FindAllStringSubmatch(live, -1) {
		path := m[1]
		if _, err := os.Stat(filepath.Join(root, path)); err != nil {
			t.Errorf("AGENTS.md points at %s, which does not exist", path)
		}
		pointed[path] = true
	}
	for _, name := range skillNames(t, root) {
		want := skillsDir + "/" + name + "/SKILL.md"
		if !pointed[want] {
			t.Errorf("skill %s has no row in the AGENTS.md skills index (expected a pointer to %s)", name, want)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "README.md")); err != nil {
		t.Errorf("README.md is pointed at by the skills index but missing: %v", err)
	}
}

// frontmatter returns the key/value pairs of a SKILL.md's single-line
// frontmatter and the body after it.
func frontmatter(t *testing.T, path string) (map[string]string, string) {
	t.Helper()
	text := readFile(t, path)
	lines := strings.Split(text, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		t.Fatalf("%s: must start with a --- frontmatter fence", path)
	}
	end := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			end = i
			break
		}
	}
	if end < 0 {
		t.Fatalf("%s: frontmatter is never closed", path)
	}
	fields := map[string]string{}
	for _, line := range lines[1:end] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok || strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
			t.Fatalf("%s: frontmatter line %q is not a single-line `key: value` (keep name and description on one line)", path, line)
		}
		fields[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return fields, strings.Join(lines[end+1:], "\n")
}

func TestSkillFrontmatterAndSize(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	for _, name := range skillNames(t, root) {
		path := filepath.Join(root, skillsDir, name, "SKILL.md")
		fields, _ := frontmatter(t, path)

		if strings.HasPrefix(name, "questmaster-") {
			t.Errorf("%s: repo skills must not start with %q: those names belong to the user-facing skills the binary ships (internal/skills)", path, "questmaster-")
		}
		if !strings.Contains(fields["description"], "Questmaster codebase itself") {
			t.Errorf("%s: description must say the skill is for working on the Questmaster codebase itself", path)
		}
		if fields["name"] != name {
			t.Errorf("%s: name %q must equal the directory %q", path, fields["name"], name)
		}
		if len(name) > skillNameMax || !skillNameRE.MatchString(name) {
			t.Errorf("%s: name %q must be lowercase letters, digits and single hyphens, at most %d characters", path, name, skillNameMax)
		}
		desc := fields["description"]
		if desc == "" {
			t.Errorf("%s: description is required", path)
		}
		if len(desc) > skillDescriptionMax {
			t.Errorf("%s: description is %d characters, over the %d limit", path, len(desc), skillDescriptionMax)
		}
		if strings.Count(readFile(t, path), "\n") > skillBodyMaxLines {
			t.Errorf("%s: over %d lines; move detail into references/", path, skillBodyMaxLines)
		}
	}
}

func TestSkillReferencesResolveOneLevelDeep(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	for _, name := range skillNames(t, root) {
		dir := filepath.Join(root, skillsDir, name)
		text := readFile(t, filepath.Join(dir, "SKILL.md"))
		for _, m := range referencePathRE.FindAllStringSubmatch(text, -1) {
			if _, err := os.Stat(filepath.Join(dir, m[1])); err != nil {
				t.Errorf("%s/SKILL.md points at %s, which does not exist", name, m[1])
			}
		}
		refs := filepath.Join(dir, "references")
		if _, err := os.Stat(refs); err != nil {
			continue
		}
		err := filepath.WalkDir(refs, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if d.IsDir() && p != refs {
				t.Errorf("%s: references must be one level deep, found directory %s", name, p)
			}
			return nil
		})
		if err != nil {
			t.Error(err)
		}
	}
}

func TestClaudeSkillSymlinksPointAtTheRealSkills(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	entries, err := os.ReadDir(filepath.Join(root, claudeSkillsDir))
	if err != nil {
		t.Fatalf("read %s: %v", claudeSkillsDir, err)
	}
	linked := map[string]bool{}
	for _, e := range entries {
		path := filepath.Join(root, claudeSkillsDir, e.Name())
		target, err := os.Readlink(path)
		if err != nil {
			t.Errorf("%s must be a symlink to the real skill, not a copy: %v", path, err)
			continue
		}
		want := filepath.Join("..", "..", skillsDir, e.Name())
		if target != want {
			t.Errorf("%s points at %q, want %q", path, target, want)
		}
		if _, err := os.Stat(filepath.Join(path, "SKILL.md")); err != nil {
			t.Errorf("%s does not resolve to a skill: %v", path, err)
		}
		linked[e.Name()] = true
	}
	for _, name := range skillNames(t, root) {
		if !linked[name] {
			t.Errorf("skill %s has no symlink in %s", name, claudeSkillsDir)
		}
	}
}

func TestSwiftSourcesCitePathsThatExist(t *testing.T) {
	t.Parallel()
	root := repoRoot(t)
	cited := 0
	err := filepath.WalkDir(filepath.Join(root, "app"), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if d.Name() == ".build" || d.Name() == "Vendor" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".swift") {
			return nil
		}
		text := readFile(t, p)
		if strings.Contains(text, "AGENTS.md, \"") {
			t.Errorf("%s cites an AGENTS.md section that no longer exists; cite the skill reference file", p)
		}
		for _, ref := range swiftSkillPathRE.FindAllString(text, -1) {
			cited++
			if _, err := os.Stat(filepath.Join(root, ref)); err != nil {
				t.Errorf("%s cites %s, which does not exist", p, ref)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if cited == 0 {
		t.Error("no Swift source or scan-test failure message names a skill reference; the scans must point at the rule")
	}
}
