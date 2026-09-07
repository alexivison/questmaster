// Package modelsuggest resolves the models a harness can be launched with at
// runtime, so a newly released model is selectable without a Questmaster
// change.
//
// Three sources feed one ranked list, best-first:
//
//  1. recent launches — models this agent has actually run here before,
//  2. the harness itself, for harnesses that can enumerate their models,
//  3. the models.dev catalog (fetched, distilled and cached under the state
//     root), including the family aliases a harness accepts.
//
// Every source is optional and every failure is quiet: with no network, no
// cache and no history the list falls back to the agent's declared role
// default. Nothing here validates a model — an id the user types is passed to
// the harness as-is, which is the only way a model released this morning can
// be used this morning.
package modelsuggest

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

const (
	// DefaultLimit is the suggestion count served when a caller asks for none.
	DefaultLimit = 24
	maxLimit     = 200
	recentLimit  = 5
)

// Source names where the bulk of a suggestion list came from, for diagnostics
// in `questmaster models` and the app.
const (
	SourceHarness = "harness"
	SourceCatalog = "catalog"
	SourceRecents = "recents"
	SourceBuiltin = "builtin"
)

// Model is one selectable model. ID is passed to the harness verbatim.
type Model struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Note  string `json:"note,omitempty"`
}

// Suggestions is the model data served to native clients and to
// `questmaster models`.
//
// Default is the model the agent launches with for this role when no override
// is given; it is reported rather than listed so clients can label their own
// "default" entry without repeating a built-in id.
type Suggestions struct {
	Agent   string  `json:"agent"`
	Role    string  `json:"role"`
	Default string  `json:"default"`
	Models  []Model `json:"models"`
	Source  string  `json:"source"`
}

// Options controls one suggestion query against already-resolved sources.
type Options struct {
	Agent   string
	Role    agent.SessionRole
	Query   string
	Limit   int
	Catalog Catalog
	// Probe enumerates the harness's own models. Nil skips harness
	// enumeration; an error from it is treated as "no harness list".
	Probe Prober
	// Store supplies recent launches. Nil skips recents.
	Store *state.Store
}

// ResolveOptions controls a full resolve: load the catalog, ask the harness,
// read recents, rank.
type ResolveOptions struct {
	Agent   string
	Role    agent.SessionRole
	Query   string
	Limit   int
	Refresh bool
	// Root is the state root holding the catalog cache. Empty disables it.
	Root string
	// Store supplies recent launches. Nil skips recents.
	Store *state.Store
	// Fetch overrides the catalog fetcher (tests).
	Fetch Fetcher
	// Prober overrides harness enumeration. Nil uses HarnessProber.
	Prober Prober
	// NoProbe skips harness enumeration entirely.
	NoProbe bool
	// Now is the catalog freshness reference. Zero means time.Now().
	Now time.Time
}

// Resolve is the one-call entry point used by the serve topic and the CLI. It
// never fails: a broken catalog, an absent harness and an empty history each
// just remove one source.
func Resolve(ctx context.Context, opts ResolveOptions) Suggestions {
	catalog, _ := LoadCatalog(ctx, CatalogOptions{
		Root:    opts.Root,
		Fetch:   opts.Fetch,
		Now:     opts.Now,
		Refresh: opts.Refresh,
	})

	probe := opts.Prober
	if opts.NoProbe {
		probe = nil
	} else if probe == nil {
		probe = HarnessProber(opts.Agent)
	}

	return Query(ctx, Options{
		Agent:   opts.Agent,
		Role:    opts.Role,
		Query:   opts.Query,
		Limit:   opts.Limit,
		Catalog: catalog,
		Probe:   probe,
		Store:   opts.Store,
	})
}

// Query ranks the models for one agent and role from already-resolved sources.
func Query(ctx context.Context, opts Options) Suggestions {
	agentName := strings.TrimSpace(opts.Agent)
	limit := opts.Limit
	if limit <= 0 {
		limit = DefaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}

	policy := agent.ModelPolicyOf(agentName)
	result := Suggestions{
		Agent:   agentName,
		Role:    RoleName(opts.Role),
		Default: agent.DefaultModelFor(agentName, opts.Role),
		Models:  []Model{},
		Source:  SourceBuiltin,
	}
	if agentName == "" {
		return result
	}

	collector := &modelCollector{seen: map[string]bool{}, query: strings.ToLower(strings.TrimSpace(opts.Query))}
	collector.addAll(recentModels(opts.Store, agentName))

	harnessIDs := probeModels(ctx, opts.Probe)
	catalogModels := catalogSuggestions(policy, opts.Catalog, harnessIDs)

	switch {
	case len(harnessIDs) > 0:
		result.Source = SourceHarness
	case len(catalogModels) > 0:
		result.Source = SourceCatalog
	case len(collector.models) > 0:
		result.Source = SourceRecents
	}

	collector.addAll(catalogModels)
	// Harness ids the catalog knows nothing about still belong in the list:
	// the harness is the authority on what it can run.
	collector.addAll(harnessOnlyModels(harnessIDs, collector))
	collector.addAll(defaultModels(policy, result.Default))

	if len(collector.models) > limit {
		collector.models = collector.models[:limit]
	}
	result.Models = collector.models
	return result
}

// RoleName renders a session role as the wire string used by the models topic
// and `questmaster models --role`.
func RoleName(role agent.SessionRole) string {
	switch role {
	case agent.RoleMaster:
		return "master"
	case agent.RoleWorker:
		return "worker"
	default:
		return "standalone"
	}
}

// ParseRole reads a role name from a request or flag. Anything unrecognized
// (including an empty value) is standalone, which is the sheet's default.
func ParseRole(value string) agent.SessionRole {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "master", "primary":
		return agent.RoleMaster
	case "worker":
		return agent.RoleWorker
	default:
		return agent.RoleStandalone
	}
}

type modelCollector struct {
	models []Model
	seen   map[string]bool
	query  string
}

func (c *modelCollector) addAll(models []Model) {
	for _, model := range models {
		c.add(model)
	}
}

func (c *modelCollector) add(model Model) {
	model.ID = strings.TrimSpace(model.ID)
	if model.ID == "" || c.seen[model.ID] {
		return
	}
	if model.Label == "" {
		model.Label = model.ID
	}
	if !c.matches(model) {
		return
	}
	c.seen[model.ID] = true
	c.models = append(c.models, model)
}

func (c *modelCollector) matches(model Model) bool {
	if c.query == "" {
		return true
	}
	return strings.Contains(strings.ToLower(model.ID), c.query) ||
		strings.Contains(strings.ToLower(model.Label), c.query)
}

func recentModels(store *state.Store, agentName string) []Model {
	ids := RecentModels(store, agentName, recentLimit)
	models := make([]Model, 0, len(ids))
	for _, id := range ids {
		models = append(models, Model{ID: id, Label: id, Note: "recent"})
	}
	return models
}

func probeModels(ctx context.Context, probe Prober) []string {
	if probe == nil {
		return nil
	}
	ids, err := probe(ctx)
	if err != nil {
		return nil
	}
	return ids
}

// catalogSuggestions renders a harness's catalog sources into its own model
// vocabulary: family aliases first where the harness accepts them (an alias
// tracks the latest model in its family, so it never goes stale), then
// concrete ids newest first.
//
// When the harness enumerated its own models, that list is authoritative:
// catalog entries outside it are dropped rather than offered as models the
// harness would reject.
func catalogSuggestions(policy agent.ModelPolicy, catalog Catalog, harnessIDs []string) []Model {
	allowed := make(map[string]bool, len(harnessIDs))
	for _, id := range harnessIDs {
		allowed[id] = true
	}

	aliases := make([]Model, 0, 4)
	concrete := make([]Model, 0, 32)
	for _, source := range policy.Sources {
		models := catalog.Models(source.Catalog)
		if len(models) == 0 {
			continue
		}
		if source.Aliases {
			aliases = append(aliases, familyAliases(models)...)
		}
		for _, model := range models {
			id := source.Prefix + model.ID
			if len(allowed) > 0 && !allowed[id] {
				continue
			}
			// The label is the id itself: it is the exact string the harness
			// receives, so a picked entry is never ambiguous. The prettier
			// vendor name goes in the note.
			concrete = append(concrete, Model{ID: id, Label: id, Note: modelNote(model)})
		}
	}
	return append(aliases, concrete...)
}

// familyAliases derives one alias per family from a provider's models, ordered
// by the newest model in each family. "claude-opus" becomes "opus".
func familyAliases(models []CatalogModel) []Model {
	type familyEntry struct {
		alias  string
		newest CatalogModel
	}
	entries := make([]familyEntry, 0, 4)
	index := make(map[string]int, 4)
	for _, model := range models {
		alias := agent.FamilyAlias(model.Family)
		if alias == "" {
			continue
		}
		if position, ok := index[alias]; ok {
			if model.ReleaseDate > entries[position].newest.ReleaseDate {
				entries[position].newest = model
			}
			continue
		}
		index[alias] = len(entries)
		entries = append(entries, familyEntry{alias: alias, newest: model})
	}
	sort.SliceStable(entries, func(i, j int) bool {
		return entries[i].newest.ReleaseDate > entries[j].newest.ReleaseDate
	})

	aliases := make([]Model, 0, len(entries))
	for _, entry := range entries {
		aliases = append(aliases, Model{
			ID:    entry.alias,
			Label: entry.alias,
			Note:  "alias · tracks " + modelName(entry.newest),
		})
	}
	return aliases
}

// harnessOnlyModels lists the harness's own ids that nothing else contributed,
// preserving the harness's order.
func harnessOnlyModels(harnessIDs []string, collector *modelCollector) []Model {
	models := make([]Model, 0, len(harnessIDs))
	for _, id := range harnessIDs {
		if collector.seen[id] {
			continue
		}
		models = append(models, Model{ID: id, Label: id})
	}
	return models
}

// defaultModels keeps the declared role defaults in the list even when every
// dynamic source came up empty, so the picker is never blank.
func defaultModels(policy agent.ModelPolicy, roleDefault string) []Model {
	models := make([]Model, 0, 3)
	for _, id := range []string{roleDefault, policy.Worker, policy.Master} {
		if strings.TrimSpace(id) == "" {
			continue
		}
		models = append(models, Model{ID: id, Label: id, Note: "built-in default"})
	}
	return models
}

func modelNote(model CatalogModel) string {
	if model.Name == "" {
		return model.ReleaseDate
	}
	if model.ReleaseDate == "" {
		return model.Name
	}
	return model.Name + " · " + model.ReleaseDate
}

func modelName(model CatalogModel) string {
	if model.Name != "" {
		return model.Name
	}
	return model.ID
}
