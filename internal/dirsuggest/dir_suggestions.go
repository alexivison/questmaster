package dirsuggest

import (
	"os"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

const defaultDirSuggestionLimit = 5

// DirQuerier returns ranked directory suggestions for a typed fragment.
type DirQuerier interface {
	QueryDirs(fragment string) ([]string, error)
}

// DirQuerierFunc adapts a function to DirQuerier.
type DirQuerierFunc func(fragment string) ([]string, error)

func (fn DirQuerierFunc) QueryDirs(fragment string) ([]string, error) {
	return fn(fragment)
}

// Suggestions is the directory data served to native clients.
type Suggestions struct {
	Suggestions []string `json:"suggestions"`
	Recents     []string `json:"recents"`
}

// NewZoxideDirQuerier returns the production zoxide-backed directory querier,
// or nil when zoxide is unavailable.
func NewZoxideDirQuerier() DirQuerier {
	return newZoxideDirQuerier()
}

// Query ranks zoxide candidates and recent session directories with the same
// fuzzy matcher used by the retired terminal picker.
func Query(store *state.Store, querier DirQuerier, query string, limit int) (Suggestions, error) {
	if limit <= 0 {
		limit = defaultDirSuggestionLimit
	}
	query = strings.TrimSpace(query)

	recents := capDirs(RecentDirs(store, limit), limit)
	if querier == nil {
		return Suggestions{
			Suggestions: capDirs(fuzzyRank(query, recents), limit),
			Recents:     recents,
		}, nil
	}

	dirs, err := querier.QueryDirs(query)
	if err != nil {
		return Suggestions{Recents: recents}, nil
	}
	return Suggestions{
		Suggestions: capDirs(fuzzyRank(query, dirs), limit),
		Recents:     recents,
	}, nil
}

// RecentDirs returns unique session working directories, most-recent first,
// capped at limit. It is derived from manifests only, with no filesystem scan.
func RecentDirs(store *state.Store, limit int) []string {
	if store == nil || limit <= 0 {
		return nil
	}
	manifests, err := store.DiscoverSessions()
	if err != nil {
		return nil
	}
	state.SortByMtime(manifests, store.Root())

	seen := make(map[string]bool, len(manifests))
	dirs := make([]string, 0, limit)
	for _, m := range manifests {
		cwd := strings.TrimSpace(m.Cwd)
		if cwd == "" || seen[cwd] {
			continue
		}
		seen[cwd] = true
		if info, err := os.Stat(cwd); err != nil || !info.IsDir() {
			continue
		}
		dirs = append(dirs, cwd)
		if len(dirs) >= limit {
			break
		}
	}
	return dirs
}

func capDirs(dirs []string, limit int) []string {
	if limit <= 0 || len(dirs) <= limit {
		return dirs
	}
	return dirs[:limit]
}
