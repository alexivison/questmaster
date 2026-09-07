//go:build linux || darwin

package cmd

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/state"
)

// offlineCatalog keeps these tests off the network: with fetching disabled and
// no cache, suggestions fall back to each harness's declared role defaults,
// which is also the shape a user sees on a plane.
func offlineCatalog(t *testing.T) {
	t.Helper()
	t.Setenv(modelsuggest.CatalogURLEnv, "off")
}

// idleRunner answers every tmux call with empty output: `models` reads no
// tmux state, so nothing should reach it.
func idleRunner() *mockRunner {
	return &mockRunner{fn: func(context.Context, ...string) (string, error) { return "", nil }}
}

func TestModelsCmdJSONReportsRoleDefault(t *testing.T) {
	offlineCatalog(t)
	store := setupStore(t)
	runner := idleRunner()

	out := runCmd(t, store, runner, "models", "claude", "--role", "master")

	var got modelsuggest.Suggestions
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("decode models JSON: %v\n%s", err, out)
	}
	if got.Agent != "claude" || got.Role != "master" {
		t.Fatalf("suggestions = %+v, want claude/master", got)
	}
	if got.Default != "opus" {
		t.Errorf("default = %q, want opus", got.Default)
	}
	if len(got.Models) == 0 {
		t.Errorf("models are empty, want the built-in defaults as a floor")
	}
}

func TestModelsCmdTextAndRecents(t *testing.T) {
	offlineCatalog(t)
	store := setupStore(t)
	runner := idleRunner()

	// A model recorded by an earlier session is offered again even though no
	// catalog and no harness knows it.
	if err := store.Create(state.Manifest{
		SessionID: "qm-recent",
		Cwd:       t.TempDir(),
		Agents:    []state.AgentManifest{{Name: "codex", Role: "primary", Model: "gpt-9-unreleased"}},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	out := runCmd(t, store, runner, "models", "codex", "--text")
	if !strings.Contains(out, "codex (standalone)") {
		t.Errorf("text output missing the header:\n%s", out)
	}
	if !strings.Contains(out, "gpt-9-unreleased") {
		t.Errorf("text output missing the recent model:\n%s", out)
	}
}

func TestModelsCmdRequiresAnAgent(t *testing.T) {
	offlineCatalog(t)
	store := setupStore(t)
	runner := idleRunner()

	if _, err := runCmdErr(t, store, runner, "models"); err == nil {
		t.Fatal("expected an error naming the available agents")
	}
}
