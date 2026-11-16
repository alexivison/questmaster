package tracker

import "github.com/alexivison/questmaster/internal/state"

// ResolveDisplayColors applies the tracker's project precedence and worker
// inheritance without querying tmux. Both the app's rows and tmux use this
// resolution path.
func ResolveDisplayColors(store *state.Store, manifests []state.Manifest) map[string]string {
	colors, _ := state.NewRepoColorStore(store.Root()).Load()
	registry, _ := state.NewProjectStore(store.Root()).Load()
	lookup := projectLookup{resolver: state.NewProjectResolver(), registry: registry, colors: colors}
	rows := make([]SessionRow, 0, len(manifests))
	for _, m := range manifests {
		row := ManifestToSessionRow(m.SessionID, m, false)
		lookup.resolveRow(&row, m)
		rows = append(rows, row)
	}
	inheritWorkerDisplayColors(rows)
	result := make(map[string]string, len(rows))
	for _, row := range rows {
		color := row.DisplayColor
		if color == "" && row.SessionType == "worker" {
			color = row.RepoColor
		}
		result[row.ID] = color
	}
	return result
}
