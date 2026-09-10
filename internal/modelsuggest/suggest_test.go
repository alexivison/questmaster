package modelsuggest

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

func testCatalog(t *testing.T) Catalog {
	t.Helper()
	catalog, err := distillCatalog([]byte(upstreamFixture), time.Unix(0, 0))
	if err != nil {
		t.Fatalf("distill catalog: %v", err)
	}
	return catalog
}

func ids(models []Model) []string {
	out := make([]string, 0, len(models))
	for _, model := range models {
		out = append(out, model.ID)
	}
	return out
}

func TestQueryRendersCatalogInEachHarnessVocabulary(t *testing.T) {
	t.Parallel()

	catalog := testCatalog(t)
	cases := []struct {
		name        string
		agent       string
		role        agent.SessionRole
		wantDefault string
		wantFirst   string
		wantIDs     []string
		absentIDs   []string
	}{
		{
			// Claude takes bare concrete ids; no family aliases are offered
			// (its "sonnet"/"opus" role defaults still appear, but only as the
			// plain built-in-default fallback — see
			// TestQueryDropsClaudeFamilyAliases).
			name:        "claude standalone",
			agent:       "claude",
			role:        agent.RoleStandalone,
			wantDefault: "sonnet",
			wantFirst:   "claude-opus-5",
			wantIDs:     []string{"claude-opus-5", "claude-sonnet-4-6"},
			absentIDs:   []string{"anthropic/claude-opus-5", "text-embedding-x"},
		},
		{
			name:        "claude master takes the master default",
			agent:       "claude",
			role:        agent.RoleMaster,
			wantDefault: "opus",
			wantFirst:   "claude-opus-5",
			wantIDs:     []string{"claude-opus-5"},
		},
		{
			// Codex takes bare OpenAI ids and no aliases.
			name:        "codex worker",
			agent:       "codex",
			role:        agent.RoleWorker,
			wantDefault: agent.CodexDefaultModel(agent.RoleWorker),
			wantFirst:   "gpt-5.6-terra",
			wantIDs:     []string{"gpt-5.6-terra"},
			absentIDs:   []string{"terra", "openai/gpt-5.6-terra", "gpt-image-2"},
		},
		{
			// Pi qualifies ids with its own provider naming.
			name:        "pi standalone",
			agent:       "pi",
			role:        agent.RoleStandalone,
			wantDefault: agent.DefaultModelFor("pi", agent.RoleStandalone),
			wantFirst:   "openai-codex/gpt-5.6-terra",
			wantIDs:     []string{"openai-codex/gpt-5.6-terra"},
			absentIDs:   []string{"gpt-5.6-terra"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()

			got := Query(context.Background(), Options{Agent: tc.agent, Role: tc.role, Catalog: catalog})
			if got.Default != tc.wantDefault {
				t.Errorf("default = %q, want %q", got.Default, tc.wantDefault)
			}
			if got.Source != SourceCatalog {
				t.Errorf("source = %q, want %q", got.Source, SourceCatalog)
			}
			if len(got.Models) == 0 || got.Models[0].ID != tc.wantFirst {
				t.Fatalf("first model = %v, want %q", ids(got.Models), tc.wantFirst)
			}
			for _, want := range tc.wantIDs {
				if !containsID(got.Models, want) {
					t.Errorf("models %v missing %q", ids(got.Models), want)
				}
			}
			for _, absent := range tc.absentIDs {
				if containsID(got.Models, absent) {
					t.Errorf("models %v should not offer %q", ids(got.Models), absent)
				}
			}
		})
	}
}

// Claude's role defaults are themselves the strings "sonnet"/"opus", so they
// still appear in the list via the built-in-default fallback — this only
// confirms the catalog no longer contributes them a second time as
// family-alias entries (which would front-load the list and carry an
// "alias · tracks ..." note).
func TestQueryDropsClaudeFamilyAliases(t *testing.T) {
	t.Parallel()

	got := Query(context.Background(), Options{Agent: "claude", Role: agent.RoleStandalone, Catalog: testCatalog(t)})
	if count := countID(got.Models, "opus"); count != 1 {
		t.Fatalf("models %v contains opus %d times, want exactly 1", ids(got.Models), count)
	}
	if note := noteForID(got.Models, "opus"); note != "the other role's built-in default" {
		t.Errorf("opus note = %q, want the built-in-default fallback, not a family alias", note)
	}
	for _, model := range got.Models {
		if strings.HasPrefix(model.Note, "alias ·") {
			t.Errorf("models %v should offer no family alias, found one at %q", ids(got.Models), model.ID)
		}
	}
}

func TestQueryPrefersHarnessEnumerationOverCatalog(t *testing.T) {
	t.Parallel()

	// OpenCode enumerates the providers the user actually configured. That
	// list is authoritative: catalog entries outside it are not offered, and
	// ids the catalog has never heard of still are.
	probe := func(context.Context) ([]string, error) {
		return []string{"opencode/big-pickle", "ollama/local-llm-9"}, nil
	}
	got := Query(context.Background(), Options{
		Agent:   "opencode",
		Role:    agent.RoleStandalone,
		Catalog: testCatalog(t),
		Probe:   probe,
	})

	if got.Source != SourceHarness {
		t.Errorf("source = %q, want %q", got.Source, SourceHarness)
	}
	for _, want := range []string{"opencode/big-pickle", "ollama/local-llm-9"} {
		if !containsID(got.Models, want) {
			t.Errorf("models %v missing %q", ids(got.Models), want)
		}
	}
	if containsID(got.Models, "anthropic/claude-opus-5") {
		t.Errorf("models %v should be limited to what the harness reported", ids(got.Models))
	}
	// opencode/big-pickle is both a harness-reported id and a catalog id (see
	// testCatalog's opencode fixture): a merge bug could offer it twice.
	if count := countID(got.Models, "opencode/big-pickle"); count != 1 {
		t.Errorf("models %v contains opencode/big-pickle %d times, want exactly 1", ids(got.Models), count)
	}
}

func TestQueryFallsBackWhenEveryDynamicSourceIsEmpty(t *testing.T) {
	t.Parallel()

	probe := func(context.Context) ([]string, error) {
		return nil, fmt.Errorf("opencode binary not found")
	}
	got := Query(context.Background(), Options{Agent: "claude", Role: agent.RoleMaster, Probe: probe})

	if got.Source != SourceBuiltin {
		t.Errorf("source = %q, want %q", got.Source, SourceBuiltin)
	}
	if got.Default != "opus" {
		t.Errorf("default = %q, want opus", got.Default)
	}
	// opus is already the reported Default; repeating it as a second list
	// entry with the same name would be the exact confusing duplicate this
	// fallback must not create. sonnet (the sibling role's default) still
	// keeps the picker non-empty.
	if containsID(got.Models, "opus") {
		t.Errorf("models = %v, should not repeat the role default already reported in Default", ids(got.Models))
	}
	if !containsID(got.Models, "sonnet") {
		t.Errorf("models = %v, want the sibling role's built-in default", ids(got.Models))
	}
}

func TestQueryLeadsWithRecentlyLaunchedModels(t *testing.T) {
	t.Parallel()

	store := seedStore(t, []state.AgentManifest{
		{Name: "claude", Role: "primary", Model: "claude-opus-9-unreleased"},
	})
	got := Query(context.Background(), Options{
		Agent:   "claude",
		Role:    agent.RoleStandalone,
		Catalog: testCatalog(t),
		Store:   store,
	})

	// A model no catalog knows about is a one-time cost: typed once, offered
	// first from then on.
	if len(got.Models) == 0 || got.Models[0].ID != "claude-opus-9-unreleased" {
		t.Fatalf("models = %v, want the recent model first", ids(got.Models))
	}
	if got.Models[0].Note != "recent" {
		t.Errorf("note = %q, want recent", got.Models[0].Note)
	}
}

// TestQueryDedupsAcrossRecentsAndCatalog guards the merge order itself: recents
// are collected first, so when the same id also appears in the catalog, the
// recents entry (and its "recent" note) must win rather than the list
// carrying the id twice.
func TestQueryDedupsAcrossRecentsAndCatalog(t *testing.T) {
	t.Parallel()

	store := seedStore(t, []state.AgentManifest{
		{Name: "claude", Role: "primary", Model: "claude-opus-5"},
	})
	got := Query(context.Background(), Options{
		Agent:   "claude",
		Role:    agent.RoleStandalone,
		Catalog: testCatalog(t),
		Store:   store,
	})

	if count := countID(got.Models, "claude-opus-5"); count != 1 {
		t.Fatalf("models %v contains claude-opus-5 %d times, want exactly 1", ids(got.Models), count)
	}
	if got.Models[0].ID != "claude-opus-5" || got.Models[0].Note != "recent" {
		t.Fatalf("first model = %+v, want claude-opus-5 with the recent note winning", got.Models[0])
	}
}

// TestQueryReportsPersistedRoleDefault guards the one place a persisted
// state.RoleDefaultsStore entry should override the reported Default: the
// harness's own hardcoded ModelPolicy stays the fallback when nothing is
// persisted.
func TestQueryReportsPersistedRoleDefault(t *testing.T) {
	t.Parallel()

	store := seedStore(t, nil)
	if err := state.NewRoleDefaultsStore(store.Root()).Set("claude", "worker", state.RoleDefault{Model: "claude-opus-9-unreleased"}); err != nil {
		t.Fatalf("seed role default: %v", err)
	}

	got := Query(context.Background(), Options{
		Agent:   "claude",
		Role:    agent.RoleStandalone,
		Catalog: testCatalog(t),
		Store:   store,
	})
	if got.Default != "claude-opus-9-unreleased" {
		t.Fatalf("default = %q, want the persisted role default", got.Default)
	}

	master := Query(context.Background(), Options{
		Agent:   "claude",
		Role:    agent.RoleMaster,
		Catalog: testCatalog(t),
		Store:   store,
	})
	if master.Default != "opus" {
		t.Fatalf("master default = %q, want the harness default unaffected by the worker override", master.Default)
	}
}

func TestQueryFiltersAndCaps(t *testing.T) {
	t.Parallel()

	catalog := testCatalog(t)

	filtered := Query(context.Background(), Options{Agent: "claude", Role: agent.RoleStandalone, Catalog: catalog, Query: "SONNET"})
	if len(filtered.Models) == 0 {
		t.Fatal("filtered models are empty")
	}
	for _, model := range filtered.Models {
		if !strings.Contains(strings.ToLower(model.ID), "sonnet") {
			t.Errorf("model %q does not match the query", model.ID)
		}
	}

	capped := Query(context.Background(), Options{Agent: "claude", Role: agent.RoleStandalone, Catalog: catalog, Limit: 2})
	if len(capped.Models) != 2 {
		t.Errorf("capped models = %d, want 2", len(capped.Models))
	}
}

func TestQueryUnknownAgentOffersNothingButFailsSoftly(t *testing.T) {
	t.Parallel()

	got := Query(context.Background(), Options{Agent: "brand-new-harness", Role: agent.RoleStandalone, Catalog: testCatalog(t)})
	if got.Default != "" {
		t.Errorf("default = %q, want empty", got.Default)
	}
	if len(got.Models) != 0 {
		t.Errorf("models = %v, want none", ids(got.Models))
	}
}

func TestRecentModelsAreScopedPerAgentAndDeduped(t *testing.T) {
	t.Parallel()

	store := seedStore(t, []state.AgentManifest{
		{Name: "claude", Role: "primary", Model: "claude-opus-5"},
		{Name: "codex", Role: "primary", Model: "gpt-5.6-sol"},
		{Name: "claude", Role: "primary", Model: "claude-opus-5"},
		{Name: "claude", Role: "primary"},
	})

	got := RecentModels(store, "claude", 5)
	if len(got) != 1 || got[0] != "claude-opus-5" {
		t.Errorf("claude recents = %v, want [claude-opus-5]", got)
	}
	if got := RecentModels(store, "codex", 5); len(got) != 1 || got[0] != "gpt-5.6-sol" {
		t.Errorf("codex recents = %v, want [gpt-5.6-sol]", got)
	}
	if got := RecentModels(nil, "claude", 5); got != nil {
		t.Errorf("recents without a store = %v, want nil", got)
	}
}

func TestRoleNamesRoundTrip(t *testing.T) {
	t.Parallel()

	for _, role := range []agent.SessionRole{agent.RoleStandalone, agent.RoleMaster, agent.RoleWorker} {
		if got := ParseRole(RoleName(role)); got != role {
			t.Errorf("ParseRole(RoleName(%v)) = %v", role, got)
		}
	}
	if got := ParseRole("nonsense"); got != agent.RoleStandalone {
		t.Errorf("ParseRole(nonsense) = %v, want standalone", got)
	}
	if got := ParseRole("primary"); got != agent.RoleMaster {
		t.Errorf("ParseRole(primary) = %v, want master", got)
	}
}

func containsID(models []Model, id string) bool {
	for _, model := range models {
		if model.ID == id {
			return true
		}
	}
	return false
}

func countID(models []Model, id string) int {
	count := 0
	for _, model := range models {
		if model.ID == id {
			count++
		}
	}
	return count
}

func noteForID(models []Model, id string) string {
	for _, model := range models {
		if model.ID == id {
			return model.Note
		}
	}
	return ""
}

// seedStore writes one session manifest per agent entry, newest last, so
// recents ordering is exercised through the real manifest discovery path.
func seedStore(t *testing.T, agents []state.AgentManifest) *state.Store {
	t.Helper()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("create store: %v", err)
	}
	for i, agentManifest := range agents {
		id := fmt.Sprintf("qm-seed-%d", i)
		if err := store.Create(state.Manifest{
			SessionID: id,
			Cwd:       t.TempDir(),
			Agents:    []state.AgentManifest{agentManifest},
		}); err != nil {
			t.Fatalf("create manifest %s: %v", id, err)
		}
	}
	return store
}
