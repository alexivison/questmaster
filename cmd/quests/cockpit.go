package main

import (
	"fmt"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/cockpit"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/review"
	"github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/state"
)

// launchCockpit builds the production data sources and runs the cockpit TUI.
func (e *env) launchCockpit() error {
	sources := e.cockpitSources()
	prog := tea.NewProgram(cockpit.New(sources), tea.WithAltScreen())
	_, err := prog.Run()
	return err
}

// cockpitSources wires the cockpit to the reused state spine (roster), the
// quest store, the runtime records, and the browser/diff launchers — all under
// the isolated Quests namespace.
func (e *env) cockpitSources() cockpit.Sources {
	store := e.store()
	rt := e.runtimeStore()
	stateStore := state.OpenStore(e.paths.StateRoot())

	return cockpit.Sources{
		Sessions: func() ([]cockpit.SessionRow, error) {
			manifests, err := stateStore.DiscoverSessions()
			if err != nil {
				return nil, err
			}
			state.SortByMtime(manifests, stateStore.Root())
			rows := make([]cockpit.SessionRow, 0, len(manifests))
			for _, m := range manifests {
				rows = append(rows, sessionRow(m))
			}
			return rows, nil
		},
		Quests: func() ([]quest.Quest, error) {
			return store.List()
		},
		Runtime: func(id string) (*runtime.RuntimeRecord, error) {
			return rt.Load(id)
		},
		OpenBrowser: func(id string) error {
			if _, err := store.Load(id); err != nil {
				return err
			}
			return e.openInBrowser(store.Path(id))
		},
		Diff: func(id string) error {
			doc, err := store.Load(id)
			if err != nil {
				return err
			}
			if doc.Head.Worktree == "" {
				return fmt.Errorf("quest %q has no worktree to diff", id)
			}
			return review.NewViewer("").Open(doc.Head.Worktree, "main")
		},
	}
}

// sessionRow projects a manifest (+ live state) into a roster row.
func sessionRow(m state.Manifest) cockpit.SessionRow {
	row := cockpit.SessionRow{
		ID:    m.SessionID,
		Title: m.Title,
		Repo:  filepath.Base(m.Cwd),
		Role:  sessionRole(m),
	}
	if row.Repo == "." || row.Repo == "/" {
		row.Repo = ""
	}
	// Live agent + state from the per-session state.json (best effort).
	if ss, err := state.LoadSessionState(m.SessionID); err == nil && ss != nil {
		if pane, ok := primaryPane(ss); ok {
			row.Agent = pane.Agent
			row.State = pane.State
		}
	}
	if row.Agent == "" && len(m.Agents) > 0 {
		row.Agent = m.Agents[0].Name
	}
	return row
}

func primaryPane(ss *state.SessionState) (state.PaneState, bool) {
	if p, ok := ss.Panes["primary"]; ok {
		return p, true
	}
	for _, p := range ss.Panes {
		return p, true
	}
	return state.PaneState{}, false
}

func sessionRole(m state.Manifest) string {
	switch {
	case m.SessionType == "master":
		return "master"
	case m.ExtraString("parent_session") != "":
		return "worker"
	default:
		return "solo"
	}
}
