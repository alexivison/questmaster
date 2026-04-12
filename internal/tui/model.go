package tui

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// workerMode is the input mode for the worker sidebar.
type workerMode int

const (
	workerModeNormal workerMode = iota
	workerModeWizard            // composing a message to the Wizard
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
	ID              string
	Mode            ViewMode
	Title           string
	Cwd             string
	ClaudeSessionID string // Claude's internal UUID for evidence lookup
}

// SessionResolver discovers the current session and its mode.
// Injected for testability — production code auto-discovers from PARTY_SESSION env.
type SessionResolver func() (SessionInfo, error)

// codexStatusMsg carries a refreshed CodexStatus from async I/O.
type codexStatusMsg struct{ status CodexStatus }

// evidenceMsg carries a refreshed evidence summary from async I/O.
type evidenceMsg struct{ entries []EvidenceEntry }

// wizardSnippetMsg carries captured Wizard pane output.
type wizardSnippetMsg struct{ snippet string }

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
	WizardSnippet   string // last captured Wizard pane output
	SessionTitle    string // from manifest
	SessionCwd      string // from manifest
	claudeSessionID string // Claude's UUID for evidence file lookup

	// Worker sidebar input mode for messaging the Wizard.
	workerMode  workerMode
	workerInput textinput.Model
	workerErr   error
	tmuxClient  *tmux.Client // for sending messages to the Wizard pane

	// resolved is true once the session identity (ID + mode) has been set.
	// After this, the ID is immutable and mode can only be promoted (worker→master).
	resolved       bool
	resolver       SessionResolver
	checkCodexPane func(sessionID string) bool // nil = use default tmux check
	trackerFactory TrackerFactory
	tracker        *TrackerModel
}

// NewModel creates a Model with auto-discovery from environment, state, and tmux.
func NewModel(store *state.Store, tc *tmux.Client) Model {
	ti := textinput.New()
	ti.CharLimit = 500
	ti.Width = 60
	ti.Placeholder = "message to Wizard..."
	return Model{
		resolver:    newAutoResolver(store, tc),
		workerInput: ti,
		tmuxClient:  tc,
	}
}

// NewModelWithResolver creates a Model with an injected resolver for testing.
func NewModelWithResolver(resolver SessionResolver) Model {
	ti := textinput.New()
	ti.CharLimit = 500
	ti.Width = 60
	ti.Placeholder = "message to Wizard..."
	return Model{resolver: resolver, workerInput: ti}
}

// Init discovers the session and starts the polling loop.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.resolveSession(), tickCmd())
}

// Update handles messages for the shared TUI shell.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		prevH := m.Height
		m.Width = msg.Width
		m.Height = msg.Height
		m.workerInput.Width = max(10, msg.Width-8)
		if m.tracker != nil {
			m.tracker.width = msg.Width
			m.tracker.height = msg.Height
			m.tracker.input.Width = max(10, msg.Width-8)
		}
		// Clear on shrink (stale trailing lines) or on first resize
		// (fallback height → real height leaves stale footer).
		if msg.Height < prevH || prevH == 0 {
			return m, tea.ClearScreen
		}
		return m, nil

	case sessionMsg:
		// If we already have a resolved session, ignore transient errors
		// (e.g., tmux returning errors when an unrelated session is killed).
		if msg.err != nil && m.resolved {
			return m, nil
		}

		var cmds []tea.Cmd
		needsClear := false
		if m.resolved {
			// Foreign session — ignore entirely.
			if msg.id != m.SessionID {
				return m, nil
			}
			// Same session: allow promotion (worker→master) and metadata refresh.
			if msg.mode == ViewMaster && m.Mode != ViewMaster {
				m.Mode = ViewMaster
				needsClear = true // layout changes entirely
			}
			m.SessionTitle = msg.title
			m.SessionCwd = msg.cwd
			m.claudeSessionID = msg.claudeSessionID
		} else {
			m.SessionID = msg.id
			m.Mode = msg.mode
			m.SessionTitle = msg.title
			m.SessionCwd = msg.cwd
			m.claudeSessionID = msg.claudeSessionID
			m.Err = msg.err
			if msg.err == nil && msg.id != "" {
				m.resolved = true
			}
		}
		if m.Mode == ViewMaster && m.tracker == nil && m.trackerFactory != nil {
			t := m.trackerFactory(m.SessionID)
			m.tracker = &t
			needsClear = true // pre-tracker render artifacts
		}
		// Single ClearScreen for any layout-disrupting transition
		// (promotion, tracker creation, or both at once).
		if needsClear {
			cmds = append(cmds, tea.ClearScreen)
		}
		if m.tracker != nil {
			m.tracker.width = m.Width
			m.tracker.height = m.Height
			m.tracker.refreshWorkers()
		}
		cmds = append(cmds, m.refreshCodexStatus(), m.refreshEvidence(), m.refreshWizardSnippet())
		return m, tea.Batch(cmds...)

	case codexStatusMsg:
		m.CodexStatus = msg.status
		return m, nil

	case evidenceMsg:
		m.Evidence = msg.entries
		return m, nil

	case wizardSnippetMsg:
		m.WizardSnippet = msg.snippet
		return m, nil

	case tickMsg, refreshMsg:
		if m.tracker != nil {
			m.tracker.refreshWorkers()
		}
		cmds := []tea.Cmd{m.resolveSession(), m.refreshCodexStatus(), m.refreshEvidence(), m.refreshWizardSnippet()}
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
		// Worker sidebar input handling
		if m.Mode == ViewWorker && m.workerMode == workerModeWizard {
			return m.updateWorkerInput(msg)
		}
		switch msg.String() {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "r":
			if m.Mode == ViewWorker {
				m.workerMode = workerModeWizard
				m.workerErr = nil
				m.workerInput.Reset()
				m.workerInput.Focus()
				return m, textinput.Blink
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

	compact := m.Width > 0 && m.Width < compactThreshold
	w := m.Width
	if w < 4 {
		w = 20
	}
	h := m.Height
	if h < 3 {
		h = 10
	}

	// Build pane title — Bold label, plain ID. Inherits terminal foreground.
	var title string
	switch m.Mode {
	case ViewMaster:
		title = sidebarLabelStyle.Render(LabelMaster+":") + " " + m.SessionID
	case ViewWorker:
		if compact {
			title = m.SessionID + " / worker"
		} else {
			title = sidebarLabelStyle.Render(LabelWorker+":") + " " + m.SessionID
		}
	}

	// Build pane body.
	var body strings.Builder
	switch m.Mode {
	case ViewWorker:
		body.WriteString(RenderSidebar(m.CodexStatus, w))
		if m.WizardSnippet != "" {
			body.WriteString(RenderWizardSnippet(m.WizardSnippet, w))
		}
		if evStr := RenderEvidence(m.Evidence, w); evStr != "" {
			body.WriteString(evStr)
		}
	case ViewMaster:
		body.WriteString(sidebarValueStyle.Render("(tracker pending)") + "\n")
	}

	// Build pane footer.
	isInputMode := m.Mode == ViewWorker && m.workerMode == workerModeWizard
	var footerParts []string
	if len(m.Evidence) > 0 {
		footerParts = append(footerParts, fmt.Sprintf("%d evidence", len(m.Evidence)))
	}
	if isInputMode {
		footerParts = append(footerParts, composerHint)
	} else {
		footerParts = append(footerParts, "r wizard")
		footerParts = append(footerParts, "q quit")
	}
	footer := sidebarHelpStyle.Render(strings.Join(footerParts, " · "))

	// Reserve space for composer below the pane.
	paneH := h
	if isInputMode {
		paneH -= composerHeight
	}
	if paneH < 3 {
		paneH = 3
	}

	result := borderlessView(title, body.String(), footer, w, paneH)

	if isInputMode {
		result += "\n" + m.renderWizardComposer(w)
	}

	return result
}

func (m Model) viewError() string {
	w := m.Width
	if w < 4 {
		w = 20
	}
	h := m.Height
	if h < 3 {
		h = 10
	}
	innerW, _ := contentDimensions(w, h)

	title := paneTitleStyle.Render("party-cli")
	footer := sidebarHelpStyle.Render("q quit")

	var body strings.Builder
	body.WriteString(errorTextStyle.Render(truncate(m.Err.Error(), innerW)) + "\n")
	body.WriteString("\n")
	body.WriteString(sidebarValueStyle.Render("Set PARTY_SESSION or run inside a party tmux session.") + "\n")

	return borderedPane(body.String(), title, footer, w, h, true)
}

// renderWizardComposer renders the message input for sending to the Wizard.
func (m Model) renderWizardComposer(width int) string {
	return renderComposerInput("wizard", m.workerInput.View(), width)
}

// updateWorkerInput handles keystrokes while composing a Wizard message.
func (m Model) updateWorkerInput(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc":
		m.workerMode = workerModeNormal
		m.workerInput.Blur()
		return m, nil

	case "enter":
		val := m.workerInput.Value()
		if val != "" && m.tmuxClient != nil {
			ctx := context.Background()
			target := tmux.CodexTarget(m.SessionID)
			result := m.tmuxClient.Send(ctx, target, val)
			m.workerErr = result.Err
		}
		m.workerMode = workerModeNormal
		m.workerInput.Blur()
		return m, tea.Tick(500*time.Millisecond, func(time.Time) tea.Msg { return refreshMsg{} })
	}

	var cmd tea.Cmd
	m.workerInput, cmd = m.workerInput.Update(msg)
	return m, cmd
}

// truncate cuts a string to maxLen visual cells, adding ellipsis if needed.
func truncate(s string, maxLen int) string {
	if maxLen <= 0 {
		return s
	}
	return ansi.Truncate(s, maxLen, "\u2026")
}

func tickCmd() tea.Cmd {
	return tea.Tick(pollInterval, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

// sessionMsg carries resolved session info from the async resolver.
type sessionMsg struct {
	id              string
	mode            ViewMode
	title           string
	cwd             string
	claudeSessionID string
	err             error
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
	evidenceID := m.claudeSessionID
	if evidenceID == "" {
		evidenceID = sessionID
	}
	return func() tea.Msg {
		entries := ReadEvidenceSummary(evidenceID, 6)
		return evidenceMsg{entries: entries}
	}
}

func (m Model) refreshWizardSnippet() tea.Cmd {
	sessionID := m.SessionID
	if sessionID == "" || m.Mode != ViewWorker {
		return nil
	}
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		target := tmux.CodexTarget(sessionID)
		captured, err := tmux.ExecRunner{}.Run(ctx, "capture-pane", "-t", target, "-p", "-S", "-500")
		if err != nil {
			return wizardSnippetMsg{}
		}
		lines := tmux.FilterWizardLines(captured, 8)
		return wizardSnippetMsg{snippet: strings.Join(lines, "\n")}
	}
}

func (m Model) resolveSession() tea.Cmd {
	resolver := m.resolver
	return func() tea.Msg {
		info, err := resolver()
		return sessionMsg{id: info.ID, mode: info.Mode, title: info.Title, cwd: info.Cwd, claudeSessionID: info.ClaudeSessionID, err: err}
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
		return SessionInfo{ID: sessionID, Mode: mode, Title: m.Title, Cwd: m.Cwd, ClaudeSessionID: m.ExtraString("claude_session_id")}, nil
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
