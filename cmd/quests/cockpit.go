package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/cockpit"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/review"
	"github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
)

// launchCockpit builds the production data sources and runs the cockpit TUI.
func (e *env) launchCockpit() error {
	prog := tea.NewProgram(cockpit.New(e.cockpitSources()), tea.WithAltScreen())
	_, err := prog.Run()
	return err
}

// cockpitSources wires the cockpit to the reused state spine (roster), the
// quest store, the runtime records, and the browser/diff/spawn/jump side
// effects — all under the isolated Quests namespace. The action hooks return
// tea.Cmds that relinquish the terminal (tea.ExecProcess) for attach/diff/edit.
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
				rows = append(rows, cockpitSessionRow(m))
			}
			return rows, nil
		},
		Quests:  func() ([]quest.Quest, error) { return store.List() },
		Runtime: func(id string) (*runtime.RuntimeRecord, error) { return rt.Load(id) },
		OpenBrowser: func(id string) error {
			if _, err := store.Load(id); err != nil {
				return err
			}
			return e.openInBrowser(store.Path(id))
		},
		Diff: func(id string) tea.Cmd {
			doc, err := store.Load(id)
			if err != nil {
				return failCmd(err)
			}
			if doc.Head.Worktree == "" {
				return failCmd(fmt.Errorf("quest %q has no worktree", id))
			}
			bin := review.ResolveViewer("")
			c := exec.Command(bin, "--base", "main", doc.Head.Worktree)
			return tea.ExecProcess(c, func(err error) tea.Msg {
				return cockpit.ActionResult{Text: "diffed " + id, Err: err}
			})
		},
		Edit: func(id string) tea.Cmd { return e.cockpitEdit(id) },
		Jump: func(sessionID string) tea.Cmd {
			return tea.ExecProcess(attachExecCmd(sessionID), func(err error) tea.Msg {
				return cockpit.ActionResult{Err: err}
			})
		},
		SpawnFree: func(title string) tea.Cmd {
			return func() tea.Msg {
				res, err := e.spawnSession(context.Background(), session.StartOpts{
					Title: title, Detached: true,
				}, "")
				return cockpit.Spawned{ID: res.SessionID, Err: err}
			}
		},
		Author: func(questID string) tea.Cmd {
			return func() tea.Msg {
				if err := e.authorQuest(questID); err != nil {
					return cockpit.Spawned{Err: err}
				}
				res, err := e.spawnSession(context.Background(), session.StartOpts{
					Title:    "plan " + questID,
					Master:   true,
					Prompt:   planningPrompt(questID, store.Path(questID)),
					Detached: true,
				}, "")
				if err == nil && res.SessionID != "" {
					_ = e.attachQuest(res.SessionID, questID)
				}
				return cockpit.Spawned{ID: res.SessionID, Err: err}
			}
		},
	}
}

// authorQuest creates a valid scaffold for a new quest id (idempotent: an
// existing quest is left as-is).
func (e *env) authorQuest(id string) error {
	store := e.store()
	if _, err := store.Load(id); err == nil {
		return nil // already exists
	}
	q := quest.Quest{ID: id, Goal: "(draft) describe the goal of " + id}
	body, err := quest.Render(q)
	if err != nil {
		return err
	}
	return store.Save(&quest.Document{Head: q, Body: body})
}

// cockpitEdit edits a quest safely (temp → validate → commit) with the editor
// taking over the terminal via tea.ExecProcess.
func (e *env) cockpitEdit(id string) tea.Cmd {
	store := e.store()
	doc, err := store.Load(id)
	if err != nil {
		return failCmd(err)
	}
	tmp, err := os.CreateTemp("", "quest-*.html")
	if err != nil {
		return failCmd(err)
	}
	tmpPath := tmp.Name()
	_, _ = tmp.Write(doc.Body)
	tmp.Close()

	editor := firstNonEmpty(os.Getenv("VISUAL"), os.Getenv("EDITOR"), "vi")
	fields := strings.Fields(editor)
	if len(fields) == 0 {
		fields = []string{"vi"}
	}
	c := exec.Command(fields[0], append(fields[1:], tmpPath)...)
	return tea.ExecProcess(c, func(execErr error) tea.Msg {
		defer os.Remove(tmpPath)
		if execErr != nil {
			return cockpit.ActionResult{Err: execErr}
		}
		edited, rerr := os.ReadFile(tmpPath)
		if rerr != nil {
			return cockpit.ActionResult{Err: rerr}
		}
		nd, perr := quest.Parse(edited)
		if perr != nil {
			return cockpit.ActionResult{Err: fmt.Errorf("edit rejected: %w", perr)}
		}
		if nd.Head.ID != id {
			return cockpit.ActionResult{Err: fmt.Errorf("edit rejected: cannot change quest id")}
		}
		if serr := store.Save(nd); serr != nil {
			return cockpit.ActionResult{Err: fmt.Errorf("edit rejected: %w", serr)}
		}
		return cockpit.ActionResult{Text: "saved " + id, Reload: true}
	})
}

func failCmd(err error) tea.Cmd {
	return func() tea.Msg { return cockpit.ActionResult{Err: err} }
}

// attachExecCmd switches to (inside tmux) or attaches (outside) the session.
func attachExecCmd(sessionID string) *exec.Cmd {
	if os.Getenv("TMUX") != "" {
		return exec.Command("tmux", "switch-client", "-t", sessionID)
	}
	return exec.Command("tmux", "attach-session", "-t", sessionID)
}

// cockpitSessionRow projects a manifest (+ live state) into a roster row with
// the activity/role/parent the tracker-style roster renders.
func cockpitSessionRow(m state.Manifest) cockpit.SessionRow {
	row := cockpit.SessionRow{
		ID:     m.SessionID,
		Title:  rosterLabel(m),
		Repo:   repoName(m.Cwd),
		Role:   sessionRole(m),
		Parent: m.ExtraString("parent_session"),
	}
	if ss, err := state.LoadSessionState(m.SessionID); err == nil && ss != nil {
		if pane, ok := primaryPane(ss); ok {
			row.Agent = pane.Agent
			row.State = pane.State
			row.Activity = pane.Activity
		}
	}
	if row.Agent == "" && len(m.Agents) > 0 {
		row.Agent = m.Agents[0].Name
	}
	return row
}

// rosterLabel prefers the title, then the attached quest id, then the session id.
func rosterLabel(m state.Manifest) string {
	if m.Title != "" {
		return m.Title
	}
	if m.QuestID != "" {
		return m.QuestID
	}
	return m.SessionID
}

func repoName(cwd string) string {
	if cwd == "" {
		return ""
	}
	base := filepath.Base(cwd)
	if base == "." || base == "/" {
		return ""
	}
	return base
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
