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

// SessionResolver discovers the current session and its mode.
// Injected for testability — production code auto-discovers from PARTY_SESSION env.
type SessionResolver func() (sessionID string, mode ViewMode, err error)

// TrackerFactory creates a TrackerModel for a given master session.
// Nil when tracker dependencies are unavailable (e.g., test stubs).
type TrackerFactory func(masterID string) TrackerModel

// Model is the shared Bubble Tea model for the party-cli TUI.
type Model struct {
	SessionID string
	Mode      ViewMode
	Width     int
	Height    int
	Err       error

	resolver       SessionResolver
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
		return m, nil

	case tickMsg, refreshMsg:
		if m.tracker != nil {
			m.tracker.refreshWorkers()
		}
		cmd := m.resolveSession()
		if _, ok := msg.(tickMsg); ok {
			return m, tea.Batch(cmd, tickCmd())
		}
		return m, cmd

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

	// Placeholder body — final views are added by Task 12 (worker) and Task 13 (master)
	b.WriteString(dimStyle.Render("  (view pending)") + "\n\n")

	// Footer
	b.WriteString(headerRule.Render("  " + strings.Repeat("\u2500", inner)) + "\n")
	if compact {
		b.WriteString(footerStyle.Render(" q:quit") + "\n")
	} else {
		b.WriteString(footerStyle.Render("  q:quit") + "\n")
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
	id   string
	mode ViewMode
	err  error
}

func (m Model) resolveSession() tea.Cmd {
	resolver := m.resolver
	return func() tea.Msg {
		id, mode, err := resolver()
		return sessionMsg{id: id, mode: mode, err: err}
	}
}

// newAutoResolver builds a SessionResolver matching the shell's discover_session:
// 1. PARTY_SESSION env override
// 2. tmux display-message when inside tmux (TMUX env set)
// 3. Scan live tmux sessions for a unique party- match
func newAutoResolver(store *state.Store, tc *tmux.Client) SessionResolver {
	return func() (string, ViewMode, error) {
		sessionID, err := discoverSessionID(tc)
		if err != nil {
			return "", ViewWorker, err
		}

		m, err := store.Read(sessionID)
		if err != nil {
			return "", ViewWorker, fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		}

		if m.SessionType == "master" {
			return sessionID, ViewMaster, nil
		}
		return sessionID, ViewWorker, nil
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
