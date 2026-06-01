package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/alexivison/questmaster/internal/quests/cockpit"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/review"
	"github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tui"
)

// launchCockpit runs the Quests dashboard (quests list + detail, live-polled).
func (e *env) launchCockpit() error {
	prog := tea.NewProgram(cockpit.New(e.cockpitSources()), tea.WithAltScreen())
	_, err := prog.Run()
	return err
}

// launchAgents runs the agents tracker — the reused questmaster tracker under
// the Quests namespace (every session across repos, live, with jump-on-Enter
// and configurable display colors). Also the in-session sidebar.
func (e *env) launchAgents() error { return tui.LaunchAgents() }

// cockpitSources wires the dashboard to the quest store + runtime records and
// the browser/diff/edit side effects, all under the isolated Quests namespace.
// Diff and Edit run via tea.ExecProcess so the dashboard is restored when the
// viewer/editor closes — the dashboard never navigates away.
func (e *env) cockpitSources() cockpit.Sources {
	store := e.store()
	rt := e.runtimeStore()
	return cockpit.Sources{
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
	}
}

// cockpitEdit edits a quest safely (temp → validate → commit) with the editor
// taking over the terminal via tea.ExecProcess, returning to the dashboard.
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

// sessionRole derives a session's role for `session ls`.
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
