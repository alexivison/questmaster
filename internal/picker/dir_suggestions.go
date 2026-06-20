package picker

import (
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

// DirSuggestions is the picker-backed directory data served to native clients.
type DirSuggestions struct {
	Suggestions []string `json:"suggestions"`
	Recents     []string `json:"recents"`
}

// NewZoxideDirQuerier returns the production zoxide-backed directory querier,
// or nil when zoxide is unavailable.
func NewZoxideDirQuerier() DirQuerier {
	return newZoxideDirQuerier()
}

// QueryDirSuggestions ranks zoxide candidates and recent session directories
// with the same fuzzy matcher used by the TUI create form.
func QueryDirSuggestions(store *state.Store, querier DirQuerier, query string, limit int) (DirSuggestions, error) {
	if limit <= 0 {
		limit = maxDirSuggestions
	}
	query = strings.TrimSpace(query)

	recents := capDirs(RecentDirs(store, limit), limit)
	if querier == nil {
		return DirSuggestions{
			Suggestions: capDirs(fuzzyRank(query, recents), limit),
			Recents:     recents,
		}, nil
	}

	dirs, err := querier.QueryDirs(query)
	if err != nil {
		return DirSuggestions{Recents: recents}, nil
	}
	return DirSuggestions{
		Suggestions: capDirs(fuzzyRank(query, dirs), limit),
		Recents:     recents,
	}, nil
}

func capDirs(dirs []string, limit int) []string {
	if limit <= 0 || len(dirs) <= limit {
		return dirs
	}
	return dirs[:limit]
}
