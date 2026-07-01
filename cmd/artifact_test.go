//go:build linux || darwin

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestArtifactAddListRemove(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-artifacts")
	workdir := t.TempDir()
	t.Chdir(workdir)

	if err := os.MkdirAll("docs", 0o755); err != nil {
		t.Fatalf("mkdir docs: %v", err)
	}
	planPath := filepath.Join(workdir, "docs", "plan.html")
	if err := os.WriteFile(planPath, []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/plan.html", "--label", "Plan")
	if !strings.Contains(out, "qm-artifacts") || !strings.Contains(out, planPath) {
		t.Fatalf("add output = %q, want session and absolute path", out)
	}
	first, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after add: %v", err)
	}
	if len(first) != 1 {
		t.Fatalf("artifacts after add = %#v, want one", first)
	}
	if first[0].Path != planPath || first[0].Kind != "html" || first[0].Label != "Plan" {
		t.Fatalf("artifact after add = %#v", first[0])
	}
	firstAddedAt := first[0].AddedAt
	if _, err := time.Parse(time.RFC3339Nano, firstAddedAt); err != nil {
		t.Fatalf("added_at = %q, want RFC3339 timestamp: %v", firstAddedAt, err)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/plan.html", "--label", "Plan v2")
	afterUpsert, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after upsert: %v", err)
	}
	if len(afterUpsert) != 1 {
		t.Fatalf("artifacts after upsert = %#v, want deduped", afterUpsert)
	}
	if afterUpsert[0].Label != "Plan v2" || afterUpsert[0].AddedAt == firstAddedAt {
		t.Fatalf("artifact after upsert = %#v, want updated label and added_at", afterUpsert[0])
	}

	if err := state.SaveSessionState("qm-artifacts", &state.SessionState{
		SessionID: "qm-artifacts",
		Version:   state.SchemaVersion,
		Panes:     map[string]state.PaneState{"primary": {Role: "primary", State: "working"}},
	}); err != nil {
		t.Fatalf("simulate old hook rewrite: %v", err)
	}

	missingPath := filepath.Join(workdir, "docs", "missing.html")
	runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/missing.html")
	listOut := runCmd(t, store, sessionsRunner(), "artifact", "ls", "--session", "qm-artifacts")
	lines := strings.Split(strings.TrimSpace(listOut), "\n")
	if len(lines) != 2 {
		t.Fatalf("ls output = %q, want two artifacts", listOut)
	}
	if !strings.Contains(lines[0], "missing") || !strings.Contains(lines[0], "missing.html") || !strings.Contains(lines[0], missingPath) {
		t.Fatalf("newest missing line = %q", lines[0])
	}
	if !strings.Contains(lines[1], "ok") || !strings.Contains(lines[1], "Plan v2") || !strings.Contains(lines[1], planPath) {
		t.Fatalf("existing artifact line = %q", lines[1])
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "1", "--session", "qm-artifacts")
	afterIndexRemove, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after index remove: %v", err)
	}
	if len(afterIndexRemove) != 1 || afterIndexRemove[0].Path != planPath {
		t.Fatalf("artifacts after index remove = %#v, want only plan", afterIndexRemove)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "docs/plan.html", "--session", "qm-artifacts")
	afterPathRemove, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after path remove: %v", err)
	}
	if len(afterPathRemove) != 0 {
		t.Fatalf("artifacts after path remove = %#v, want none", afterPathRemove)
	}
}

func TestArtifactAddInfersAndOverridesKind(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-artifact-kind")
	workdir := t.TempDir()
	t.Chdir(workdir)

	if err := os.WriteFile("report.md", []byte("# Report"), 0o644); err != nil {
		t.Fatalf("write markdown artifact: %v", err)
	}
	if err := os.WriteFile("diagram.png", []byte("not really a png"), 0o644); err != nil {
		t.Fatalf("write image artifact: %v", err)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "add", "report.md")
	runCmd(t, store, sessionsRunner(), "artifact", "add", "diagram.png", "--kind", "html")

	artifacts, err := state.LoadArtifacts("qm-artifact-kind")
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}

	kinds := map[string]string{}
	for _, artifact := range artifacts {
		kinds[filepath.Base(artifact.Path)] = artifact.Kind
	}
	if kinds["report.md"] != state.ArtifactKindMarkdown {
		t.Fatalf("report.md kind = %q, want markdown", kinds["report.md"])
	}
	if kinds["diagram.png"] != state.ArtifactKindHTML {
		t.Fatalf("diagram.png kind = %q, want override html", kinds["diagram.png"])
	}
}
