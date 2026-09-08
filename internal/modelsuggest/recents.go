package modelsuggest

import (
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

// RecentModels returns the models previously launched with an agent, most
// recent first, derived from session manifests only (no filesystem scan beyond
// the manifests themselves).
//
// Recents are what make an unknown model a one-time cost: a model the catalog
// has never heard of is typed once, and every later session offers it.
func RecentModels(store *state.Store, agentName string, limit int) []string {
	agentName = strings.TrimSpace(agentName)
	if store == nil || agentName == "" || limit <= 0 {
		return nil
	}
	manifests, err := store.DiscoverSessions()
	if err != nil {
		return nil
	}
	state.SortByMtime(manifests, store.Root())

	seen := make(map[string]bool, limit)
	models := make([]string, 0, limit)
	for _, manifest := range manifests {
		for _, agentManifest := range manifest.Agents {
			if agentManifest.Name != agentName {
				continue
			}
			model := strings.TrimSpace(agentManifest.Model)
			if model == "" || seen[model] {
				continue
			}
			seen[model] = true
			models = append(models, model)
			if len(models) >= limit {
				return models
			}
		}
	}
	return models
}
