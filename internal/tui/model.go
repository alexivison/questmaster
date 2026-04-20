package tui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// pollInterval is the standard tick cadence for data refresh.
const pollInterval = 3 * time.Second

// blinkInterval is the cadence for blinking the activity dot on working sessions.
const blinkInterval = 600 * time.Millisecond

// tickMsg triggers a periodic refresh.
type tickMsg time.Time

// refreshMsg triggers an immediate one-shot refresh.
type refreshMsg struct{}

// blinkMsg toggles the activity-dot blink phase.
type blinkMsg struct{}

// SessionInfo holds resolved session metadata.
type SessionInfo struct {
	ID          string
	Title       string
	Cwd         string
	SessionType string
	Manifest    state.Manifest
	Registry    *agent.Registry
}

// SessionResolver discovers the current session.
// Injected for testability — production code auto-discovers from PARTY_SESSION env.
type SessionResolver func() (SessionInfo, error)

type autoResolver struct {
	store *state.Store
	tc    *tmux.Client

	mu sync.Mutex

	loaded        bool
	envSession    string
	sessionID     string
	manifestPath  string
	manifestMTime time.Time
	configPath    string
	configMTime   time.Time
	info          SessionInfo
	err           error
	cfg           *agent.Config
	registry      *agent.Registry
}

// Model is the shared Bubble Tea model for the party-cli TUI.
type Model struct {
	SessionID string
	Width     int
	Height    int
	Err       error

	tracker      TrackerModel
	resolved     bool
	resolver     SessionResolver
	autoResolver *autoResolver
	registry     *agent.Registry
}

// NewModel creates a Model with auto-discovery from environment, state, and tmux.
func NewModel(store *state.Store, tc *tmux.Client) Model {
	auto := newAutoResolver(store, tc)
	return Model{
		resolver:     auto.Resolve,
		autoResolver: auto,
		tracker:      NewTrackerModel(SessionInfo{}, nil, nil),
	}
}

// NewModelWithResolver creates a Model with an injected resolver for testing.
func NewModelWithResolver(resolver SessionResolver) Model {
	return Model{
		resolver: resolver,
		tracker:  NewTrackerModel(SessionInfo{}, nil, nil),
	}
}

// Init discovers the session and starts the polling loop.
func (m Model) Init() tea.Cmd {
	return tea.Batch(m.resolveSession(), tickCmd(), blinkCmd())
}

// Update handles messages for the unified TUI shell.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		prevH := m.Height
		m.Width = msg.Width
		m.Height = msg.Height
		m.tracker.width = msg.Width
		m.tracker.height = msg.Height
		m.tracker.input.Width = max(10, msg.Width-8)
		if msg.Height < prevH || prevH == 0 {
			return m, tea.ClearScreen
		}
		return m, nil

	case sessionMsg:
		if msg.err != nil && m.resolved {
			return m, nil
		}
		if msg.err != nil {
			m.Err = msg.err
			return m, nil
		}

		if m.resolved && msg.info.ID != m.SessionID {
			return m, nil
		}

		m.SessionID = msg.info.ID
		m.registry = msg.info.Registry
		m.Err = nil
		m.resolved = msg.info.ID != ""
		m.tracker.SetCurrent(msg.info)
		return m, m.tracker.requestRefresh()

	case tickMsg, refreshMsg:
		cmds := []tea.Cmd{m.resolveSession()}
		if refresh := m.tracker.requestRefresh(); refresh != nil {
			cmds = append(cmds, refresh)
		}
		if _, ok := msg.(tickMsg); ok {
			cmds = append(cmds, tickCmd())
		}
		return m, tea.Batch(cmds...)

	case snapshotMsg:
		return m, m.tracker.finishRefresh(msg)

	case blinkMsg:
		m.tracker.blinkOn = !m.tracker.blinkOn
		return m, blinkCmd()

	case tea.KeyMsg:
		t, cmd := m.tracker.Update(msg)
		m.tracker = t
		return m, cmd
	}

	return m, nil
}

// View renders the current TUI state.
func (m Model) View() string {
	if m.Err != nil {
		return m.viewError()
	}
	return m.tracker.View()
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

func blinkCmd() tea.Cmd {
	return tea.Tick(blinkInterval, func(time.Time) tea.Msg {
		return blinkMsg{}
	})
}

// sessionMsg carries resolved session info from the async resolver.
type sessionMsg struct {
	info SessionInfo
	err  error
}

func (m Model) resolveSession() tea.Cmd {
	resolver := m.resolver
	return func() tea.Msg {
		info, err := resolver()
		return sessionMsg{info: info, err: err}
	}
}

// newAutoResolver builds a SessionResolver matching the shell's discover_session:
// 1. PARTY_SESSION env override
// 2. tmux display-message when inside tmux (TMUX env set)
// 3. Scan live tmux sessions for a unique party- match
func newAutoResolver(store *state.Store, tc *tmux.Client) *autoResolver {
	return &autoResolver{store: store, tc: tc}
}

func registryForManifest(manifest state.Manifest) *agent.Registry {
	cfg, err := agent.LoadConfig(nil)
	if err == nil {
		registry, regErr := agent.NewRegistry(cfg)
		if regErr == nil {
			return registry
		}
	}
	return builtinAgentRegistry
}

func (r *autoResolver) Resolve() (SessionInfo, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	envSession := os.Getenv("PARTY_SESSION")
	sessionID := r.sessionID
	if !r.loaded || envSession != r.envSession || sessionID == "" {
		var err error
		sessionID, err = discoverSessionID(r.tc)
		if err != nil {
			r.loaded = true
			r.envSession = envSession
			r.sessionID = ""
			r.info = SessionInfo{}
			r.err = err
			return SessionInfo{}, err
		}
	}

	configPath, configMTime := configFileState()
	manifestPath := manifestPathFor(r.store, sessionID)
	manifestMTime := fileMTime(manifestPath)

	if r.loaded &&
		envSession == r.envSession &&
		sessionID == r.sessionID &&
		configPath == r.configPath &&
		configMTime.Equal(r.configMTime) &&
		manifestPath == r.manifestPath &&
		manifestMTime.Equal(r.manifestMTime) {
		return r.info, r.err
	}

	manifest, err := r.store.Read(sessionID)
	if err != nil {
		err = fmt.Errorf("cannot read manifest for %s: %w", sessionID, err)
		r.loaded = true
		r.envSession = envSession
		r.sessionID = sessionID
		r.configPath = configPath
		r.configMTime = configMTime
		r.manifestPath = manifestPath
		r.manifestMTime = manifestMTime
		r.info = SessionInfo{}
		r.err = err
		return SessionInfo{}, err
	}

	registry := r.registry
	if registry == nil || configPath != r.configPath || !configMTime.Equal(r.configMTime) {
		r.cfg, registry = loadCachedRegistry()
		r.registry = registry
	}

	info := SessionInfo{
		ID:          sessionID,
		Title:       manifest.Title,
		Cwd:         manifest.Cwd,
		SessionType: sessionTypeForManifest(manifest),
		Manifest:    manifest,
		Registry:    registry,
	}

	r.loaded = true
	r.envSession = envSession
	r.sessionID = sessionID
	r.configPath = configPath
	r.configMTime = configMTime
	r.manifestPath = manifestPath
	r.manifestMTime = manifestMTime
	r.info = info
	r.err = nil
	return info, nil
}

func loadCachedRegistry() (*agent.Config, *agent.Registry) {
	cfg, err := agent.LoadConfig(nil)
	if err == nil {
		registry, regErr := agent.NewRegistry(cfg)
		if regErr == nil {
			return cfg, registry
		}
	}
	return nil, builtinAgentRegistry
}

func configFileState() (string, time.Time) {
	path, err := agent.UserConfigPath()
	if err != nil {
		return "", time.Time{}
	}
	return path, fileMTime(path)
}

func manifestPathFor(store *state.Store, sessionID string) string {
	if store == nil || sessionID == "" {
		return ""
	}
	return filepath.Join(store.Root(), sessionID+".json")
}

func fileMTime(path string) time.Time {
	if path == "" {
		return time.Time{}
	}
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

// discoverSessionID mirrors session/party-lib.sh:discover_session().
func discoverSessionID(tc *tmux.Client) (string, error) {
	if id := os.Getenv("PARTY_SESSION"); id != "" {
		return id, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

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
