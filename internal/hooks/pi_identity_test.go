package hooks

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

var (
	piFamiliarTable = regexp.MustCompile(`(?s)const familiars: Record<string, string> = \{(.*?)\};`)
	piFamiliarEntry = regexp.MustCompile(`(\w+): "([^"]+)"`)
	swiftFamiliar   = regexp.MustCompile(`case \.(\w+): "([^"]+)"`)
)

// TestPiIdentityMatchesSessionClasses keeps the class ids and familiar names the Pi
// extension reads in step with the Go class list and the Swift familiar names.
func TestPiIdentityMatchesSessionClasses(t *testing.T) {
	t.Parallel()
	table := piFamiliarTable.FindStringSubmatch(piMessagingExtension)
	if table == nil {
		t.Fatal("Pi extension has no familiars table")
	}
	pi := map[string]string{}
	for _, m := range piFamiliarEntry.FindAllStringSubmatch(table[1], -1) {
		pi[m[1]] = m[2]
	}
	source, err := os.ReadFile(filepath.Join("..", "..", "app", "Sources", "Core", "Mutations", "SessionClassLogic.swift"))
	if err != nil {
		t.Fatal(err)
	}
	swift := map[string]string{}
	for _, m := range swiftFamiliar.FindAllStringSubmatch(string(source), -1) {
		swift[m[1]] = m[2]
	}
	classes := state.SessionClasses()
	if len(pi) != len(classes) || len(swift) != len(classes) {
		t.Fatalf("class counts: Go %d, Pi extension %d, Swift %d", len(classes), len(pi), len(swift))
	}
	for _, class := range classes {
		if pi[class] == "" || pi[class] != swift[class] {
			t.Errorf("class %q: Pi familiar %q, Swift familiar %q", class, pi[class], swift[class])
		}
	}
}

// TestPiIdentityAndCommands runs the identity and command checks against the Pi
// extension: the footer status per role, and /workers and /quests.
func TestPiIdentityAndCommands(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is unavailable")
	}
	if err := exec.Command(node, "--experimental-strip-types", "-e", "").Run(); err != nil {
		t.Skip("Node TypeScript type stripping is unavailable")
	}
	extension, err := filepath.Abs(filepath.Join("assets", "questmaster-pi-messaging.ts"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, node, "--experimental-strip-types", filepath.Join("testdata", "pi_identity.mjs"), extension).CombinedOutput()
	if err != nil {
		t.Fatalf("Pi identity and commands check: %v\n%s", err, out)
	}
}
