package tmuxconfig

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
)

// StatusResult describes the dedicated server and the config it reads at start.
type StatusResult struct {
	Config                 string `json:"config"`
	Enforced               string `json:"enforced"`
	EffectiveLabel         string `json:"effective_label"`
	Running                bool   `json:"running"`
	StartedUnix            int64  `json:"started_unix"`
	Sessions               int    `json:"sessions"`
	EditedSinceStart       bool   `json:"edited_since_start"`
	EnforcedPending        bool   `json:"enforced_pending"`
	TemplateVersion        int    `json:"template_version"`
	BuiltinTemplateVersion int    `json:"builtin_template_version"`
}

type ReloadResult struct {
	Running bool     `json:"running"`
	Errors  []string `json:"errors"`
}

type CheckResult struct {
	OK             bool     `json:"ok"`
	Errors         []string `json:"errors"`
	EffectiveLabel string   `json:"effective_label"`
}

type RestartResult struct {
	Restarted bool `json:"restarted"`
	Refused   bool `json:"refused"`
	Sessions  int  `json:"sessions"`
}

var templateHeader = regexp.MustCompile(`template v([0-9]+)`)
var enforcedMarker = regexp.MustCompile(`(?m)^set -g @questmaster_enforced ([0-9]+)$`)

// Status reads files and a running server without creating either one.
func Status(ctx context.Context, client *tmux.Client, root string) (StatusResult, error) {
	paths := Paths(root)
	label, err := tmux.EffectiveLabel()
	if err != nil {
		return StatusResult{}, err
	}
	result := StatusResult{Config: paths.Config, Enforced: paths.Enforced, EffectiveLabel: label}
	result.BuiltinTemplateVersion = headerVersion(string(template))
	result.TemplateVersion, err = fileHeaderVersion(paths.Config)
	if err != nil {
		return StatusResult{}, err
	}
	started, sessions, running, err := serverState(ctx, client)
	if err != nil {
		return StatusResult{}, err
	}
	if !running {
		return result, nil
	}
	result.Running, result.StartedUnix, result.Sessions = true, started, sessions
	info, err := os.Stat(paths.Config)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return StatusResult{}, err
	}
	if err == nil {
		result.EditedSinceStart = info.ModTime().After(time.Unix(started, 0))
	}
	marker, err := client.RunBatch(ctx, []string{"show-options", "-gqv", "@questmaster_enforced"})
	if err != nil {
		return StatusResult{}, fmt.Errorf("read enforced marker: %w", err)
	}
	want := enforcedMarker.FindStringSubmatch(enforcedBlock)
	if len(want) != 2 {
		return StatusResult{}, fmt.Errorf("built-in enforced marker is missing")
	}
	result.EnforcedPending = strings.TrimSpace(marker) != want[1]
	return result, nil
}

func headerVersion(header string) int {
	first, _, _ := strings.Cut(header, "\n")
	match := templateHeader.FindStringSubmatch(first)
	if len(match) != 2 {
		return 0
	}
	version, _ := strconv.Atoi(match[1])
	return version
}

func fileHeaderVersion(path string) (int, error) {
	f, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	if !scanner.Scan() {
		return 0, scanner.Err()
	}
	return headerVersion(scanner.Text()), nil
}

func serverState(ctx context.Context, client *tmux.Client) (int64, int, bool, error) {
	out, err := client.RunBatch(ctx, []string{"display-message", "-p", "-F", "#{start_time}|#{server_sessions}"})
	if isNoServer(err) {
		return 0, 0, false, nil
	}
	if err != nil {
		return 0, 0, false, fmt.Errorf("read tmux server state: %w", err)
	}
	startText, sessionsText, ok := strings.Cut(strings.TrimSpace(out), "|")
	if !ok {
		return 0, 0, false, fmt.Errorf("invalid tmux server state %q", out)
	}
	started, err := strconv.ParseInt(startText, 10, 64)
	if err != nil {
		return 0, 0, false, fmt.Errorf("invalid tmux start time %q: %w", startText, err)
	}
	sessions, err := strconv.Atoi(sessionsText)
	if err != nil {
		return 0, 0, false, fmt.Errorf("invalid tmux session count %q: %w", sessionsText, err)
	}
	return started, sessions, true, nil
}

func isNoServer(err error) bool {
	var exit *tmux.ExitError
	if !errors.As(err, &exit) {
		return false
	}
	return strings.Contains(exit.Stderr, "no server running") ||
		(strings.Contains(exit.Stderr, "error connecting") && strings.Contains(exit.Stderr, "No such file or directory"))
}

// Reload applies both files in order. Source errors are data so the caller can
// show every tmux diagnostic; the enforced file is sourced even if the user
// file has errors.
func Reload(ctx context.Context, client *tmux.Client, root string) (ReloadResult, error) {
	_, _, running, err := serverState(ctx, client)
	if err != nil || !running {
		return ReloadResult{Running: running, Errors: []string{}}, err
	}
	paths := Paths(root)
	result := ReloadResult{Running: true, Errors: []string{}}
	for _, path := range []string{paths.Config, paths.Enforced} {
		_, err := client.RunBatch(ctx, []string{"source-file", path})
		if err == nil {
			continue
		}
		var exit *tmux.ExitError
		if !errors.As(err, &exit) {
			return result, err
		}
		result.Errors = append(result.Errors, configErrors(exit.Stderr, err)...)
	}
	return result, nil
}

// RestartIfEmpty asks tmux to test the session count and kill the server in
// one command. The else branch prints the count from that same decision.
func RestartIfEmpty(ctx context.Context, client *tmux.Client) (RestartResult, error) {
	out, err := client.RunBatch(ctx, []string{"if-shell", "-F", "#{==:#{server_sessions},0}", "kill-server", `display-message -p -F "#{server_sessions}"`})
	if isNoServer(err) {
		return RestartResult{}, nil
	}
	if err != nil {
		return RestartResult{}, err
	}
	if strings.TrimSpace(out) == "" {
		// kill-server returns before the server process is gone, so a status or a
		// new session right after this call could still reach the dying server.
		if err := waitForServerExit(ctx, client); err != nil {
			return RestartResult{}, err
		}
		return RestartResult{Restarted: true}, nil
	}
	sessions, err := strconv.Atoi(strings.TrimSpace(out))
	if err != nil || sessions < 0 {
		return RestartResult{}, fmt.Errorf("invalid tmux restart refusal count %q", out)
	}
	return RestartResult{Refused: true, Sessions: sessions}, nil
}

// serverExitTimeout bounds how long a restart waits for the killed server to go.
const serverExitTimeout = 2 * time.Second

// serverExitPoll is how often the wait asks whether the server is still there.
const serverExitPoll = 20 * time.Millisecond

// waitForServerExit polls until the server no longer answers. list-sessions
// never starts a server, so polling cannot bring it back.
func waitForServerExit(ctx context.Context, client *tmux.Client) error {
	ctx, cancel := context.WithTimeout(ctx, serverExitTimeout)
	defer cancel()
	for {
		_, err := client.RunBatch(ctx, []string{"list-sessions"})
		if isNoServer(err) {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("tmux server did not exit within %s after kill-server", serverExitTimeout)
		case <-time.After(serverExitPoll):
		}
	}
}
