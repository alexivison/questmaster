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

func TestModelsCmdRejectsInvalidRole(t *testing.T) {
	offlineCatalog(t)
	store := setupStore(t)
	runner := idleRunner()

	if _, err := runCmdErr(t, store, runner, "models", "claude", "--role", "wrker"); err == nil {
		t.Fatal("expected an error for an invalid --role value, not a silent standalone fallback")
	}
}

// minimalCatalogFixture is a fetch response just large enough for
// distillCatalog to keep one model: tool-calling, text output.
const minimalCatalogFixture = `{
  "anthropic": {
    "id": "anthropic",
    "models": {
      "claude-opus-5": {
        "id": "claude-opus-5",
        "name": "Claude Opus 5",
        "family": "claude-opus",
        "release_date": "2026-01-01",
        "tool_call": true,
        "modalities": {"output": ["text"]}
      }
    }
  }
}`

// TestModelsCmdRefreshForcesRefetchPastFreshCache proves --refresh at the CLI
// layer, not just at modelsuggest.LoadCatalog's own level: a second `models`
// call without --refresh must reuse the cache seeded by the first (no new
// fetch), while --refresh must force a new fetch even though the cache is
// still fresh. modelsCatalogFetch substitutes for the network entirely, so
// this never reaches models.dev.
func TestModelsCmdRefreshForcesRefetchPastFreshCache(t *testing.T) {
	// Deliberately not offlineCatalog(t): this test needs fetching enabled,
	// just pointed at a stub instead of the network.
	store := setupStore(t)
	runner := idleRunner()

	calls := 0
	modelsCatalogFetch = func(context.Context, string) ([]byte, error) {
		calls++
		return []byte(minimalCatalogFixture), nil
	}
	t.Cleanup(func() { modelsCatalogFetch = nil })

	runCmd(t, store, runner, "models", "claude")
	if calls != 1 {
		t.Fatalf("fetch calls after first run = %d, want 1", calls)
	}

	runCmd(t, store, runner, "models", "claude")
	if calls != 1 {
		t.Fatalf("fetch calls after a second run with no --refresh = %d, want 1 (cache still fresh)", calls)
	}

	runCmd(t, store, runner, "models", "claude", "--refresh")
	if calls != 2 {
		t.Fatalf("fetch calls after --refresh = %d, want 2 (refresh bypasses the fresh cache)", calls)
	}
}
