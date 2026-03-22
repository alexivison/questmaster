package tui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// ViewMode determines which top-level view the TUI renders.
type ViewMode int

const (
	// ViewWorker renders the worker/standalone sidebar shell.
	ViewWorker ViewMode = iota
	// ViewMaster renders the master tracker shell.
	ViewMaster
)

func (v ViewMode) String() string {
	switch v {
	case ViewWorker:
		return "worker"
	case ViewMaster:
		return "master"
	default:
		return "unknown"
	}
}

// pollInterval is the standard tick cadence for data refresh.
const pollInterval = 3 * time.Second

// tickMsg triggers a periodic refresh.
type tickMsg time.Time

// refreshMsg triggers an immediate one-shot refresh.
type refreshMsg struct{}

// SessionInfo holds resolved session metadata.
type SessionInfo struct {
	ID    string
	Mode  ViewMode
	Title string
	Cwd   string
}

// SessionResolver discovers the current session and its mode.
// Injected for testability — production code auto-discovers from PARTY_SESSION env.
type SessionResolver func() (SessionInfo, error)

// codexStatusMsg carries a refreshed CodexStatus from async I/O.
type codexStatusMsg struct{ status CodexStatus }

// evidenceMsg carries a refreshed evidence summary from async I/O.
type evidenceMsg struct{ entries []EvidenceEntry }

// peekResultMsg carries the outcome of a peek popup attempt.
type peekResultMsg struct{ err error }

// TrackerFactory creates a TrackerModel for a given master session.
// Nil when tracker dependencies are unavailable (e.g., test stubs).
type TrackerFactory func(masterID string) TrackerModel

// Model is the shared Bubble Tea model for the party-cli TUI.
type Model struct {
	SessionID       string
	Mode            ViewMode
	Width           int
	Height          int
	Err             error
	CodexStatus     CodexStatus
	Evidence        []EvidenceEntry
	PeekMsg         string // transient message from peek attempt
	SessionTitle    string // from manifest
	SessionCwd      string // from manifest

	resolver       SessionResolver
	checkCodexPane func(sessionID string) bool // nil = use default tmux check
	trackerFactory TrackerFactory
	tracker        *TrackerModel
}

// NewModel creates a Model with auto-discovery from environment, state, and tmux.
func NewModel(store *state.Store, tc *tmux.Client) Model {
	return Model{
		resolver: newAutoResolver(store, tc),
	}
}

// NewModelWithResolver creates a Model with an injected resolver for testing.
func NewModelWithResolver(resolver SessionResolver) Model {
	return Model{resolver: resolver}
}

// Init discovers the session and starts the polling loop.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.resolveSession(), tickCmd())
}

// Update handles messages for the shared TUI shell.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.Width = msg.Width
		m.Height = msg.Height
		if m.tracker != nil {
			m.tracker.width = msg.Width
			m.tracker.height = msg.Height
			m.tracker.input.Width = max(10, msg.Width-8)
		}
		return m, nil

	case sessionMsg:
		m.SessionID = msg.id
		m.Mode = msg.mode
		m.SessionTitle = msg.title
		m.SessionCwd = msg.cwd
		m.Err = msg.err
		if msg.mode == ViewMaster && m.tracker == nil && m.trackerFactory != nil {
			t := m.trackerFactory(msg.id)
			m.tracker = &t
		}
		if m.tracker != nil {
			m.tracker.width = m.Width
			m.tracker.height = m.Height
			m.tracker.refreshWorkers()
		}
		return m, tea.Batch(m.refreshCodexStatus(), m.refreshEvidence())

	case codexStatusMsg:
		m.CodexStatus = msg.status
		return m, nil

	case evidenceMsg:
		m.Evidence = msg.entries
		return m, nil

	case peekResultMsg:
		if msg.err != nil {
			m.PeekMsg = msg.err.Error()
		} else {
			m.PeekMsg = ""
		}
		return m, nil

	case tickMsg, refreshMsg:
		if m.tracker != nil {
			m.tracker.refreshWorkers()
		}
		cmds := []tea.Cmd{m.resolveSession(), m.refreshCodexStatus(), m.refreshEvidence()}
		if _, ok := msg.(tickMsg); ok {
			cmds = append(cmds, tickCmd())
		}
		return m, tea.Batch(cmds...)

	case tea.KeyMsg:
		// Delegate to tracker in master mode
		if m.Mode == ViewMaster && m.tracker != nil {
			t, cmd := m.tracker.Update(msg)
			m.tracker = &t
			return m, cmd
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "p":
			if m.Mode == ViewWorker {
				return m, m.openPeekPopup()
			}
		}
	}

	return m, nil
}

// View renders the current TUI state.
func (m Model) View() string {
	if m.Err != nil {
		return m.viewError()
	}

	// Master mode with tracker: delegate entirely
	if m.Mode == ViewMaster && m.tracker != nil {
		return m.tracker.View()
	}

	// Worker mode or fallback (no tracker factory)
	var b strings.Builder
	inner := m.innerWidth()
	compact := m.Width > 0 && m.Width < compactThreshold

	switch m.Mode {
	case ViewMaster:
		if compact {
			b.WriteString(titleStyle.Render(truncate(fmt.Sprintf(" %s", m.SessionID), inner)) + "\n")
			b.WriteString(dimStyle.Render(" master") + "\n")
		} else {
			b.WriteString(titleStyle.Render(fmt.Sprintf("  Master: %s", m.SessionID)) + "\n")
		}
	case ViewWorker:
		if compact {
			b.WriteString(titleStyle.Render(truncate(fmt.Sprintf(" %s", m.SessionID), inner)) + "\n")
			b.WriteString(dimStyle.Render(" worker") + "\n")
		} else {
			b.WriteString(titleStyle.Render(fmt.Sprintf("  Worker: %s", m.SessionID)) + "\n")
		}
	}
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n\n")

	switch m.Mode {
	case ViewWorker:
		// Session context
		if m.SessionTitle != "" {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  title: %s", truncate(m.SessionTitle, inner-10))) + "\n")
		}
		if m.SessionCwd != "" {
			b.WriteString(dimStyle.Render(fmt.Sprintf("  cwd: %s", truncate(m.SessionCwd, inner-8))) + "\n")
		}
		if m.SessionTitle != "" || m.SessionCwd != "" {
			b.WriteString("\n")
		}

		b.WriteString(RenderSidebar(m.CodexStatus, m.Width))
		if evStr := RenderEvidence(m.Evidence, m.Width); evStr != "" {
			b.WriteString(evStr)
		}
		if m.PeekMsg != "" {
			b.WriteString(warnStyle.Render(fmt.Sprintf("  %s", m.PeekMsg)) + "\n")
		}
		b.WriteString("\n")
	case ViewMaster:
		// Master tracker view — Task 13
		b.WriteString(dimStyle.Render("  (tracker pending)") + "\n\n")
	}

	// Footer
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n")
	if compact {
		b.WriteString(footerStyle.Render(" q:quit p:peek") + "\n")
	} else {
		b.WriteString(footerStyle.Render("  q:quit  p:peek codex") + "\n")
	}

	return b.String()
}

func (m Model) viewError() string {
	var b strings.Builder
	inner := m.innerWidth()

	b.WriteString(titleStyle.Render("  party-cli") + "\n")
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n\n")
	b.WriteString(fmt.Sprintf("  %s\n\n", m.Err))
	b.WriteString(dimStyle.Render("  Set PARTY_SESSION or run inside a party tmux session.") + "\n\n")
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n")
	b.WriteString(footerStyle.Render("  q:quit") + "\n")

	return b.String()
}

// innerWidth returns usable content width after padding.
func (m Model) innerWidth() int {
	w := m.Width - 4 // 2 char padding each side
	if w < 10 {
		w = 10
	}
	return w
}

// truncate cuts a string to maxLen, adding ellipsis if needed.
func truncate(s string, maxLen int) string {
	if maxLen <= 0 || len(s) <= maxLen {
		return s
	}
	if maxLen <= 1 {
		return "\u2026"
	}
	return s[:maxLen-1] + "\u2026"
}

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// sessionMsg carries resolved session info from the async resolver.
type sessionMsg struct {
	id    string
	mode  ViewMode
	title string
	cwd   string
	err   error
}

func (m Model) refreshCodexStatus() tea.Cmd {
	sessionID := m.SessionID
	if sessionID == "" {
		return nil
	}
	checker := m.checkCodexPane
	if checker == nil {
		checker = defaultCodexPaneCheck
	}
	return func() tea.Msg {
		cs, _ := ReadCodexStatus(fmt.Sprintf("/tmp/%s", sessionID))

		// Override to offline if Codex window 0 is gone
		if cs.State != CodexOffline && !checker(sessionID) {
			cs = CodexStatus{State: CodexOffline}
		}

		return codexStatusMsg{status: cs}
	}
}

func defaultCodexPaneCheck(sessionID string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	target := tmux.CodexTarget(sessionID)
	runner := tmux.ExecRunner{}
	_, err := runner.Run(ctx, "display-message", "-t", target, "-p", "")
	return err == nil
}

func (m Model) refreshEvidence() tea.Cmd {
	sessionID := m.SessionID
	if sessionID == "" {
		return nil
	}
	return func() tea.Msg {
		entries := ReadEvidenceSummary(sessionID, 6)
		return evidenceMsg{entries: entries}
	}
}

func (m Model) openPeekPopup() tea.Cmd {
	sessionID := m.SessionID
	if sessionID == "" {
		return nil
	}
	codexAvailable := m.CodexStatus.State != CodexOffline
	return func() tea.Msg {
		args := PeekPopupArgs(sessionID, codexAvailable)
		if args == nil {
			return peekResultMsg{err: fmt.Errorf("Codex unavailable")}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, err := tmux.ExecRunner{}.Run(ctx, args...)
		return peekResultMsg{err: err}
	}
}

func (m Model) resolveSession() tea.Cmd {
	resolver := m.resolver
	return func() tea.Msg {
		info, err := resolver()
		return sessionMsg{id: info.ID, mode: info.Mode, title: info.Title, cwd: info.Cwd, err: err}
	}
}

// newAutoResolver builds a SessionResolver matching the shell's discover_session:
// 1. PARTY_SESSION env override
// 2. tmux display-message when inside tmux (TMUX env set)
// 3. Scan live tmux sessions for a unique party- match
func newAutoResolver(store *state.Store, tc *tmux.Client) SessionResolver {
	return func() (SessionInfo, error) {
		sessionID, err := discoverSessionID(tc)
		if err != nil {
			return SessionInfo{}, err
		}

		m, err := store.Read(sessionID)
		if err != nil {
			return SessionInfo{}, fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		}

		mode := ViewWorker
		if m.SessionType == "master" {
			mode = ViewMaster
		}
		return SessionInfo{ID: sessionID, Mode: mode, Title: m.Title, Cwd: m.Cwd}, nil
	}
}

// discoverSessionID mirrors session/party-lib.sh:discover_session().
func discoverSessionID(tc *tmux.Client) (string, error) {
	// 1. Explicit override
	if id := os.Getenv("PARTY_SESSION"); id != "" {
		return id, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	// 2. Inside tmux — ask for the current session name (no fallthrough)
	if os.Getenv("TMUX") != "" {
		name, err := tc.CurrentSessionName(ctx)
		if err != nil {
			return "", fmt.Errorf("cannot detect tmux session: %w", err)
		}
		if !strings.HasPrefix(name, "party-") {
			return "", fmt.Errorf("current tmux session %q is not a party session", name)
		}
		return name, nil
	}

	// 3. Not inside tmux — scan for a unique party session
	sessions, err := tc.ListSessions(ctx)
	if err != nil {
		return "", fmt.Errorf("session discovery failed: %w", err)
	}
	return disambiguatePartySessions(sessions)
}

// disambiguatePartySessions finds the unique party- session or errors.
func disambiguatePartySessions(sessions []string) (string, error) {
	var matches []string
	for _, s := range sessions {
		if strings.HasPrefix(s, "party-") {
			matches = append(matches, s)
		}
	}
	switch len(matches) {
	case 0:
		return "", fmt.Errorf("no party session found")
	case 1:
		return matches[0], nil
	default:
		return "", fmt.Errorf("multiple party sessions found (%d) — set PARTY_SESSION to disambiguate", len(matches))
	}
}
