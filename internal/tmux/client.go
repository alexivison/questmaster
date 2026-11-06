package tmux

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const (
	// WindowWorkspace is the window index recorded for a session's agent and
	// searched first by role lookups. It is a preference, never a target: a
	// server with base-index 1 numbers that window 1, role lookups then search
	// every window, and launch targets the pane ID new-session reports.
	WindowWorkspace = 0

	// DefaultSendTimeout bounds one whole Send, lock wait to Enter.
	DefaultSendTimeout = 2 * time.Second

	// PaneRoleOption is the tmux user-option key storing a pane's questmaster role.
	PaneRoleOption = "@party_role"
	// PaneRemainOnExit is the tmux pane option that keeps panes alive after exit.
	PaneRemainOnExit = "remain-on-exit"
	// PaneBorderStatusOption is the tmux window option controlling pane border status.
	PaneBorderStatusOption = "pane-border-status"
	// PaneBorderStatusTop positions the pane border status at the top.
	PaneBorderStatusTop = "top"

	// Pane role values stored under PaneRoleOption.
	RoleAgent = "agent"
	RoleShell = "shell"
)

// SessionTarget returns the exact tmux target for a session, "=session:". A
// bare name matches by prefix (has-session -t qm-1 finds qm-12 once qm-1 is
// gone), and "=session" without the colon fails in commands whose -t names a
// pane, such as set-option, set-hook and respawn-pane.
func SessionTarget(sessionID string) string {
	return "=" + sessionID + ":"
}

// PaneTarget returns the exact tmux target "=session:window.pane".
func PaneTarget(sessionID string, windowIdx, paneIdx int) string {
	return fmt.Sprintf("=%s:%d.%d", sessionID, windowIdx, paneIdx)
}

// Pane represents a tmux pane with its role metadata.
type Pane struct {
	SessionName string
	WindowIndex int
	PaneIndex   int
	Role        string // PaneRoleOption value
}

// Target returns the tmux target string for this pane.
func (p Pane) Target() string {
	return PaneTarget(p.SessionName, p.WindowIndex, p.PaneIndex)
}

// SendResult represents the outcome of a send-keys attempt. Submitted is true once
// the text and Enter were typed into the pane.
type SendResult struct {
	Submitted bool
	Target    string
	Err       error
}

// Runner runs tmux commands on one server and returns stdout. Server is the
// production Runner; tests pass fakes.
type Runner interface {
	Run(ctx context.Context, args ...string) (string, error)
}

// defaultServerLabel is the label tmux itself uses when nothing selects a
// server. A server label lives at /tmp/tmux-<uid>/<label>.
const defaultServerLabel = "default"

// Server selects one tmux server. Every command it runs names that server
// with -L or -S, and the command's environment drops TMUX, TMUX_PANE and
// TMUX_TMPDIR: they describe the caller's own server, which need not be this
// one. Build one with DefaultServer or SocketServer.
type Server struct {
	flag        string // "-L" names a label in tmux's socket directory; "-S" a socket path
	name        string
	configFiles []string
}

// Label returns the selected -L name, or the private socket path for -S tests.
func (s Server) Label() string { return s.name }

var _ Runner = Server{}

// DefaultServer is the server Questmaster's sessions run on. It is the one
// place production picks a server. "-L default" is the socket tmux falls back
// to when no flag, TMUX or TMUX_TMPDIR selects another, /tmp/tmux-<uid>/default,
// which is also the socket the app's own tmux calls reach.
func DefaultServer() Server {
	return LegacyServer()
}

// LegacyServer selects the user's default socket independently of the
// creation selector. Recorded legacy sessions always route here.
func LegacyServer() Server {
	return Server{flag: "-L", name: defaultServerLabel}
}

// EffectiveLabel resolves the dedicated server label. The override is for
// isolated development and tests; an invalid value is always an error.
func EffectiveLabel() (string, error) {
	label, set := os.LookupEnv("QUESTMASTER_TMUX_LABEL")
	if !set {
		return "questmaster", nil
	}
	if err := ValidateNamedLabel(label); err != nil {
		return "", fmt.Errorf("invalid QUESTMASTER_TMUX_LABEL %q: %w", label, err)
	}
	return label, nil
}

// ValidateNamedLabel accepts an explicit dedicated-server label. Routing a
// recorded session must never consult QUESTMASTER_TMUX_LABEL.
func ValidateNamedLabel(label string) error {
	if label == "default" || len(label) == 0 || len(label) > 32 {
		return fmt.Errorf("invalid named tmux label %q", label)
	}
	for i := 0; i < len(label); i++ {
		c := label[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return fmt.Errorf("invalid named tmux label %q", label)
		}
	}
	return nil
}

// NamedServer selects Questmaster's dedicated server with the user config
// followed by the enforced settings. No production caller uses it yet.
func NamedServer(config, enforced string) (Server, error) {
	label, err := EffectiveLabel()
	if err != nil {
		return Server{}, err
	}
	return NamedServerLabel(label, config, enforced)
}

// NamedServerLabel addresses a recorded label, independently of the current
// development override. It is used only by the routing provider.
func NamedServerLabel(label, config, enforced string) (Server, error) {
	if err := ValidateNamedLabel(label); err != nil {
		return Server{}, err
	}
	return Server{flag: "-L", name: label, configFiles: []string{config, enforced}}, nil
}

// SocketServer selects the server listening on socket. Tests use it with a
// private socket.
func SocketServer(socket string) Server {
	return Server{flag: "-S", name: socket}
}

// SocketServerWithConfig selects a private socket with startup config files.
// It is useful when validating a configuration without selecting a named server.
func SocketServerWithConfig(socket string, files ...string) Server {
	return Server{flag: "-S", name: socket, configFiles: append([]string(nil), files...)}
}

// Command returns a tmux command on this server. Run uses it; attach runs one
// directly so tmux gets the terminal.
func (s Server) Command(ctx context.Context, args ...string) *exec.Cmd {
	argv := []string{s.flag, s.name}
	for _, file := range s.configFiles {
		argv = append(argv, "-f", file)
	}
	cmd := exec.CommandContext(ctx, "tmux", append(argv, args...)...)
	cmd.Dir = "/"
	cmd.Env = serverEnv(os.Environ())
	return cmd
}

// Run executes a tmux command on this server and returns its trimmed stdout.
// Wraps non-zero exits as *ExitError (with stderr) so callers can distinguish
// "session not found" from transport errors.
func (s Server) Run(ctx context.Context, args ...string) (string, error) {
	out, err := s.Command(ctx, args...).Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", &ExitError{
				Code:   exitErr.ExitCode(),
				Stderr: strings.TrimRight(string(exitErr.Stderr), "\n"),
			}
		}
		return "", err
	}
	return strings.TrimRight(string(out), "\n"), nil
}

// serverEnv drops the variables that route a tmux client to a server or socket
// directory other than the one the command names. TMUX would also make
// new-session refuse to nest.
func serverEnv(environ []string) []string {
	env := make([]string, 0, len(environ))
	for _, kv := range environ {
		switch key, _, _ := strings.Cut(kv, "="); key {
		case "TMUX", "TMUX_PANE", "TMUX_TMPDIR", "QUESTMASTER_SESSION", "QUESTMASTER_TMUX_SERVER", "QUESTMASTER_RUNTIME_DIR":
			continue
		}
		env = append(env, kv)
	}
	return env
}

// ExitError indicates a tmux command ran but exited with a non-zero status.
// This distinguishes "tmux ran but failed" from "tmux binary not found".
// Stderr is captured so callers can distinguish "session not found" from
// transport errors (connection refused, no server running, etc.).
type ExitError struct {
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	if e.Stderr != "" {
		return fmt.Sprintf("tmux exited with status %d: %s", e.Code, e.Stderr)
	}
	return fmt.Sprintf("tmux exited with status %d", e.Code)
}

// IsConnectionError returns true if the error indicates an active tmux
// transport failure (permission denied, server crash) rather than the
// benign "no tmux server exists yet" case. The distinction matters because
// "no server" is functionally equivalent to "session not found", while a
// real transport failure (e.g. socket with wrong permissions) should not be
// silently treated as "session stopped".
func (e *ExitError) IsConnectionError() bool {
	s := e.Stderr
	if strings.Contains(s, "lost server") {
		return true
	}
	if strings.Contains(s, "error connecting") && !strings.Contains(s, "No such file or directory") {
		return true
	}
	return false
}

// Client provides typed tmux operations on one server.
type Client struct {
	runner      Runner
	SendTimeout time.Duration

	cacheMu              sync.Mutex
	listSessionsTTL      time.Duration
	listSessionsCachedAt time.Time
	listSessionsCached   []string
	listSessionsErr      error
}

// NewClient creates a Client that runs every command on server. Production
// passes DefaultServer(); tests pass a fake Runner.
func NewClient(server Runner) *Client {
	return &Client{runner: server, SendTimeout: DefaultSendTimeout}
}

// CacheListSessions enables a short-lived cache for the expensive tmux
// list-sessions call. Call ClearListSessionsCache when durable session state
// changes so push-driven refreshes still observe real changes promptly.
func (c *Client) CacheListSessions(ttl time.Duration) {
	if c == nil {
		return
	}
	c.cacheMu.Lock()
	defer c.cacheMu.Unlock()
	c.listSessionsTTL = ttl
	c.listSessionsCachedAt = time.Time{}
	c.listSessionsCached = nil
	c.listSessionsErr = nil
}

func (c *Client) ClearListSessionsCache() {
	if c == nil {
		return
	}
	c.cacheMu.Lock()
	c.listSessionsCachedAt = time.Time{}
	c.listSessionsCached = nil
	c.listSessionsErr = nil
	c.cacheMu.Unlock()
}

// RunBatch executes multiple tmux commands sequentially, stopping on the
// first error. Each element of cmds is a slice of args for one command.
// Returns the output of the last successful command (usually empty for
// set-option/select-pane).
func (c *Client) RunBatch(ctx context.Context, cmds ...[]string) (string, error) {
	var lastOut string
	for _, cmd := range cmds {
		out, err := c.runner.Run(ctx, cmd...)
		if err != nil {
			return "", err
		}
		lastOut = out
	}
	return lastOut, nil
}
