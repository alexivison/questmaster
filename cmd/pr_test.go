package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPRCommands(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("QUESTMASTER_BIN", filepath.Join(store.Root(), "canonical-qm"))
	ensureCalls, wakeCalls := 0, 0
	prEnsure = func(_ context.Context, config daemon.Config) (daemon.Record, error) {
		ensureCalls++
		if config.Root != store.Root() {
			t.Fatalf("daemon root=%s", config.Root)
		}
		if ensureCalls == 1 {
			prs, err := state.LoadPullRequests(store.Root())
			if err != nil || len(prs) != 0 {
				t.Fatalf("ensure happened after watch: %v %v", prs, err)
			}
		}
		return daemon.Record{}, fmt.Errorf("daemon unavailable")
	}
	prRequest = func(_ context.Context, _ daemon.Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		wakeCalls++
		if !wait {
			t.Fatal("watch did not wait for verification")
		}
		prs, err := state.LoadPullRequests(store.Root())
		if err != nil || len(prs) == 0 {
			t.Fatalf("wake before registry write: %v %v", prs, err)
		}
		if len(keys) != 1 || keys[0] != "github.com/owner/repo#7" && keys[0] != "github.com/other/repo#8" {
			t.Fatalf("wake keys=%v", keys)
		}
		return map[string]prstatus.HostResult{"github.com": {CheckedAt: "2026-10-28T00:00:00Z"}}, nil
	}
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	if err := store.Create(state.Manifest{SessionID: "qm-pr", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-other", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	var result struct {
		Key     string `json:"key"`
		Added   bool   `json:"added"`
		Removed bool   `json:"removed"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "Owner/Repo#7")), &result); err != nil || !result.Added || result.Key != "github.com/owner/repo#7" {
		t.Fatalf("watch = %#v, %v", result, err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "https://github.com/owner/repo/pull/7")), &result); err != nil || result.Added {
		t.Fatalf("repeat watch = %#v, %v", result, err)
	}
	if ensureCalls != 2 || wakeCalls != 1 {
		t.Fatalf("ensure=%d wake=%d", ensureCalls, wakeCalls)
	}
	var prs []state.PullRequest
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &prs); err != nil || len(prs) != 1 || len(prs[0].Watchers) != 1 {
		t.Fatalf("ls = %#v, %v", prs, err)
	}
	if _, err := time.Parse(time.RFC3339Nano, prs[0].Watchers[0].AddedAt); err != nil {
		t.Fatal(err)
	}
	if _, err := state.RecordPullRequestEvents(store.Root(), prs[0].Key, []state.PullRequestEvent{{ID: "comment-1", Kind: "comment", OccurredAt: time.Now().Add(time.Minute).UTC().Format(time.RFC3339Nano), Body: "```ignore me```"}}, nil); err != nil {
		t.Fatal(err)
	}
	var pending []struct {
		Watchers []struct {
			UndeliveredAlerts int `json:"undelivered_alerts"`
		} `json:"watchers"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &pending); err != nil || len(pending) != 1 || len(pending[0].Watchers) != 1 || pending[0].Watchers[0].UndeliveredAlerts != 1 {
		t.Fatalf("ls pending = %+v, %v", pending, err)
	}
	if err := state.AdvancePullRequestAlert(store.Root(), prs[0].Key, "qm-pr", 1); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &pending); err != nil || pending[0].Watchers[0].UndeliveredAlerts != 0 {
		t.Fatalf("ls delivered = %+v, %v", pending, err)
	}
	var events []state.PullRequestEvent
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "events", "owner/repo#7", "--unread")), &events); err != nil || len(events) != 1 || strings.Contains(events[0].Body, "```") {
		t.Fatalf("events = %#v, %v", events, err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "events", "owner/repo#7", "--unread")), &events); err != nil || len(events) != 0 {
		t.Fatalf("reread events = %#v, %v", events, err)
	}
	runCmd(t, store, sessionsRunner(), "pr", "watch", "other/repo#8", "--session", "qm-other")
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls", "--all")), &prs); err != nil || len(prs) != 2 {
		t.Fatalf("ls --all = %#v, %v", prs, err)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "unwatch", "owner/repo#7")), &result); err != nil || !result.Removed {
		t.Fatalf("unwatch = %#v, %v", result, err)
	}
	if got := runCmd(t, store, sessionsRunner(), "pr", "ls"); strings.TrimSpace(got) != "[]" {
		t.Fatalf("ls after unwatch = %q", got)
	}
}

func TestPRWatchVerifiesNewWatch(t *testing.T) {
	for _, tc := range []struct {
		name       string
		status     state.PullRequestStatus
		host       prstatus.HostResult
		requestErr error
		wantError  string
		wantWatch  bool
	}{
		{name: "not found", status: state.PullRequestStatus{InaccessibleReason: "not_found"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantError: "github.com/owner/repo#7 not found; check the owner, repo and number"},
		{name: "accessible", status: state.PullRequestStatus{State: "open"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantWatch: true},
		{name: "forbidden", status: state.PullRequestStatus{InaccessibleReason: "forbidden"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantError: "github.com/owner/repo#7 is inaccessible (forbidden)"},
		{name: "saml", status: state.PullRequestStatus{InaccessibleReason: "saml"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantError: "github.com/owner/repo#7 is inaccessible (saml)"},
		{name: "unknown", status: state.PullRequestStatus{InaccessibleReason: "unknown"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantWatch: true},
		{name: "daemon error", requestErr: fmt.Errorf("daemon unavailable"), wantWatch: true},
		{name: "timeout", requestErr: context.DeadlineExceeded, wantWatch: true},
		{name: "backoff", status: state.PullRequestStatus{InaccessibleReason: "not_found"}, host: prstatus.HostResult{BackoffUntil: "2026-10-28T00:01:00Z"}, wantWatch: true},
		{name: "host error", status: state.PullRequestStatus{InaccessibleReason: "not_found"}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z", Error: "rate limit"}, wantWatch: true},
		{name: "stale status", status: state.PullRequestStatus{InaccessibleReason: "not_found", Stale: true}, host: prstatus.HostResult{CheckedAt: "2026-10-28T00:00:00Z"}, wantWatch: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stubPRDaemon(t)
			store := setupStore(t)
			t.Setenv("HOME", t.TempDir())
			t.Setenv(state.StateRootEnv, store.Root())
			t.Setenv(state.SessionEnv, "qm-pr")
			if err := store.Create(state.Manifest{SessionID: "qm-pr", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
				t.Fatal(err)
			}
			calls := 0
			prRequest = func(ctx context.Context, config daemon.Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
				calls++
				deadline, ok := ctx.Deadline()
				if !wait || !ok || time.Until(deadline) > 15*time.Second || len(keys) != 1 || keys[0] != "github.com/owner/repo#7" {
					t.Fatalf("verification request: wait=%v deadline=%v keys=%v", wait, deadline, keys)
				}
				if tc.requestErr != nil {
					return nil, tc.requestErr
				}
				if tc.status != (state.PullRequestStatus{}) {
					if err := state.SavePullRequestStatuses(config.Root, map[string]state.PullRequestStatus{keys[0]: tc.status}, nil); err != nil {
						t.Fatal(err)
					}
				}
				return map[string]prstatus.HostResult{"github.com": tc.host}, nil
			}
			out, err := runCmdErr(t, store, sessionsRunner(), "pr", "watch", "owner/repo#7")
			if tc.wantError == "" {
				if err != nil || !strings.Contains(out, `"added": true`) {
					t.Fatalf("watch output=%q error=%v", out, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("watch output=%q error=%v", out, err)
			}
			prs, loadErr := state.LoadPullRequests(store.Root())
			if loadErr != nil || (len(prs) == 1) != tc.wantWatch || calls != 1 {
				t.Fatalf("registry=%v loadErr=%v requests=%d", prs, loadErr, calls)
			}
			if tc.wantWatch {
				out, err = runCmdErr(t, store, sessionsRunner(), "pr", "watch", "owner/repo#7")
				if err != nil || !strings.Contains(out, `"added": false`) || calls != 1 {
					t.Fatalf("rewatch output=%q error=%v requests=%d", out, err, calls)
				}
			}
		})
	}
}

func TestPRWatchRejectsPlainSession(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	if err := store.Create(state.Manifest{SessionID: "qm-shell"}); err != nil {
		t.Fatal(err)
	}
	_, err := runCmdErr(t, store, sessionsRunner(), "pr", "watch", "owner/repo#1", "--session", "qm-shell")
	if err == nil || !strings.Contains(err.Error(), "has no agent") {
		t.Fatalf("watch plain session: %v", err)
	}
	prs, err := state.LoadPullRequests(store.Root())
	if err != nil || len(prs) != 0 {
		t.Fatalf("plain watch registry=%v err=%v", prs, err)
	}
}

func TestPRWatchHostAllowlist(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	if err := store.Create(state.Manifest{SessionID: "qm-pr", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	existing, _ := state.ParsePullRequestRef("owner/repo#7")
	if _, err := state.WatchPullRequest(store.Root(), "qm-pr", existing, time.Now()); err != nil {
		t.Fatal(err)
	}
	oldHosts := prLoggedInHosts
	t.Cleanup(func() { prLoggedInHosts = oldHosts })
	prLoggedInHosts = func() ([]string, error) { return []string{"other.example"}, nil }
	_, err := runCmdErr(t, store, sessionsRunner(), "pr", "watch", "https://ghe.example/owner/repo/pull/1", "--session", "qm-pr")
	if err == nil || !strings.Contains(err.Error(), "accepted: github.com, other.example") {
		t.Fatalf("watch on unlisted host: %v", err)
	}
	prs, err := state.LoadPullRequests(store.Root())
	if err != nil || len(prs) != 1 || prs[0].Key != existing.Key {
		t.Fatalf("rejected watch changed the registry: %#v, %v", prs, err)
	}

	prLoggedInHosts = func() ([]string, error) { return []string{"ghe.example"}, nil }
	var result struct {
		Key   string `json:"key"`
		Added bool   `json:"added"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "https://ghe.example/owner/repo/pull/1", "--session", "qm-pr")), &result); err != nil || !result.Added || result.Key != "ghe.example/owner/repo#1" {
		t.Fatalf("watch on logged-in host = %#v, %v", result, err)
	}
}

func TestPREventsPreviewAndFull(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-reader")
	for _, id := range []string{"qm-reader", "qm-watcher"} {
		if err := store.Create(state.Manifest{SessionID: id, Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
			t.Fatal(err)
		}
	}
	ref, _ := state.ParsePullRequestRef("owner/repo#7")
	if _, err := state.WatchPullRequest(store.Root(), "qm-watcher", ref, time.Now().Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	body := "```" + strings.Repeat("🎯", 120) + "```"
	humanBody := strings.Repeat("h", 500)
	if _, err := state.RecordPullRequestEvents(store.Root(), ref.Key, []state.PullRequestEvent{
		{ID: "comment-1", Kind: "comment", OccurredAt: time.Now().UTC().Format(time.RFC3339Nano), Body: body, Bot: true},
		{ID: "comment-2", Kind: "comment", OccurredAt: time.Now().UTC().Format(time.RFC3339Nano), Body: humanBody},
	}, nil); err != nil {
		t.Fatal(err)
	}
	type eventOutput struct {
		state.PullRequestEvent
		Untrusted bool   `json:"untrusted"`
		Notice    string `json:"notice"`
	}
	var preview []struct {
		eventOutput
		BodyTruncated bool `json:"body_truncated"`
		BodyBytes     int  `json:"body_bytes"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "events", "owner/repo#7")), &preview); err != nil || len(preview) != 2 || !preview[0].BodyTruncated || preview[0].BodyBytes != len(body) || len(preview[0].Body) > 200 || !utf8.ValidString(preview[0].Body) || strings.Contains(preview[0].Body, "```") || !preview[1].BodyTruncated || preview[1].BodyBytes != len(humanBody) || len(preview[1].Body) != 400 {
		t.Fatalf("preview = %#v, %v", preview, err)
	}
	for _, event := range preview {
		if !event.Untrusted || event.Notice == "" {
			t.Fatalf("preview event lacks untrusted marking: %#v", event)
		}
	}
	var full []eventOutput
	fullJSON := runCmd(t, store, sessionsRunner(), "pr", "events", "owner/repo#7", "--full")
	if err := json.Unmarshal([]byte(fullJSON), &full); err != nil || len(full) != 2 || full[0].Body != strings.ReplaceAll(body, "```", "\\`\\`\\`") || full[1].Body != humanBody || strings.Contains(fullJSON, "body_truncated") {
		t.Fatalf("full = %#v, %v", full, err)
	}
	for _, event := range full {
		if !event.Untrusted || event.Notice == "" {
			t.Fatalf("full event lacks untrusted marking: %#v", event)
		}
	}
	log, err := state.LoadPullRequestEventLog(store.Root(), ref.Key)
	if err != nil || len(log.Events) != 2 || log.Events[0].Body != body || log.Events[1].Body != humanBody {
		t.Fatalf("stored body = %#v, %v", log.Events, err)
	}
}

func TestPRDaemonConfigPrefersInstalledCanonicalOverDevShim(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	canonical := filepath.Join(home, "canonical-qm")
	if err := os.WriteFile(canonical, []byte("binary"), 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(canonical, link); err != nil {
		t.Fatal(err)
	}
	t.Setenv("QUESTMASTER_BIN", filepath.Join(home, "dev-shim"))
	config := prDaemonConfig(t.TempDir())
	resolved, err := filepath.EvalSymlinks(canonical)
	if err != nil {
		t.Fatal(err)
	}
	if config.Executable != resolved {
		t.Fatalf("PR daemon executable=%s, want canonical %s", config.Executable, resolved)
	}
	id, err := daemon.Identity(config.Root, home, config.Executable)
	if err != nil || id != "canonical" {
		t.Fatalf("daemon identity=%s err=%v", id, err)
	}
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	current, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if got := prDaemonConfig(t.TempDir()).Executable; got != current {
		t.Fatalf("without installed link executable=%s, want current %s", got, current)
	}
}

func TestPRRefreshUsesWatchedScopeAndPersistsStatus(t *testing.T) {
	stubPRDaemon(t)
	t.Setenv("HOME", t.TempDir())
	var refreshed [][]string
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	for _, id := range []string{"qm-pr", "qm-other"} {
		if err := store.Create(state.Manifest{SessionID: id, Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
			t.Fatal(err)
		}
	}
	if got := runCmd(t, store, sessionsRunner(), "pr", "refresh"); !strings.Contains(got, `"pull_requests": []`) {
		t.Fatalf("empty refresh = %s", got)
	}
	prRequest = func(_ context.Context, config daemon.Config, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
		if !wait {
			return map[string]prstatus.HostResult{}, nil
		}
		refreshed = append(refreshed, append([]string(nil), keys...))
		updates := map[string]state.PullRequestStatus{}
		for _, key := range keys {
			updates[key] = state.PullRequestStatus{Title: "From fake daemon", State: "open", ChangedAt: time.Now().UTC().Format(time.RFC3339)}
		}
		if err := state.SavePullRequestStatuses(config.Root, updates, nil); err != nil {
			return nil, err
		}
		return map[string]prstatus.HostResult{"github.com": {RateLimit: &prstatus.RateLimit{Cost: 1}, CheckedAt: "2026-10-28T00:00:00Z"}}, nil
	}
	runCmd(t, store, sessionsRunner(), "pr", "watch", "o/r#1")
	runCmd(t, store, sessionsRunner(), "pr", "watch", "o/r#2", "--session", "qm-other")
	var result struct {
		PullRequests []state.PullRequest `json:"pull_requests"`
		Hosts        map[string]struct {
			CheckedAt string `json:"checked_at"`
			RateLimit struct {
				Cost int `json:"cost"`
			} `json:"rate_limit"`
		} `json:"hosts"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh")), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.PullRequests) != 1 || result.PullRequests[0].Status.Title != "From fake daemon" || result.Hosts["github.com"].RateLimit.Cost != 1 || result.Hosts["github.com"].CheckedAt != "2026-10-28T00:00:00Z" {
		t.Fatalf("refresh=%#v", result)
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh", "--all")), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.PullRequests) != 2 {
		t.Fatalf("all=%#v", result.PullRequests)
	}
	if len(refreshed) != 4 || len(refreshed[0]) != 1 || len(refreshed[1]) != 1 || len(refreshed[2]) != 1 || len(refreshed[3]) != 2 {
		t.Fatalf("refresh scopes=%v", refreshed)
	}
	var listed []state.PullRequest
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "ls")), &listed); err != nil || len(listed) != 1 || listed[0].Status == nil {
		t.Fatalf("ls=%#v err=%v", listed, err)
	}
}

func TestPRRefreshFailsWithoutDaemon(t *testing.T) {
	stubPRDaemon(t)
	t.Setenv("HOME", t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	if err := store.Create(state.Manifest{SessionID: "qm-pr"}); err != nil {
		t.Fatal(err)
	}
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) {
		return daemon.Record{}, fmt.Errorf("unreachable")
	}
	cmd := NewRootCmd(WithDeps(store, tmux.NewClient(sessionsRunner())))
	cmd.SetArgs([]string{"pr", "refresh"})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "running daemon") {
		t.Fatalf("error=%v", err)
	}
}

func stubPRDaemon(t *testing.T) {
	t.Helper()
	oldEnsure, oldRequest := prEnsure, prRequest
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) { return daemon.Record{}, nil }
	prRequest = func(context.Context, daemon.Config, []string, bool) (map[string]prstatus.HostResult, error) {
		return map[string]prstatus.HostResult{}, nil
	}
	t.Cleanup(func() { prEnsure, prRequest = oldEnsure, oldRequest })
}

// holdJobsLock plays the daemon that owns PR jobs on the root.
func holdJobsLock(t *testing.T, root string) {
	t.Helper()
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(filepath.Join(dir, "jobs.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { lock.Close() })
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
}

func setupPRSession(t *testing.T) *state.Store {
	t.Helper()
	store := setupStore(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-pr")
	if err := store.Create(state.Manifest{SessionID: "qm-pr", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	return store
}

func TestPRWatchReportsMonitoringUnavailableWhenNoDaemonPolls(t *testing.T) {
	stubPRDaemon(t)
	store := setupPRSession(t)
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) {
		return daemon.Record{}, fmt.Errorf("daemon unavailable")
	}
	prRequest = func(context.Context, daemon.Config, []string, bool) (map[string]prstatus.HostResult, error) {
		return nil, fmt.Errorf("PR polling is unavailable on this daemon")
	}
	var result struct {
		Added      bool   `json:"added"`
		Monitoring string `json:"monitoring"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "owner/repo#7")), &result); err != nil {
		t.Fatal(err)
	}
	if !result.Added || result.Monitoring != "unavailable" {
		t.Fatalf("watch = %#v, want added with unavailable monitoring", result)
	}
}

func TestPRWatchReportsMonitoringActiveWhileAnotherDaemonHoldsJobs(t *testing.T) {
	stubPRDaemon(t)
	store := setupPRSession(t)
	prEnsure = func(context.Context, daemon.Config) (daemon.Record, error) {
		return daemon.Record{}, fmt.Errorf("daemon unavailable")
	}
	holdJobsLock(t, store.Root())
	var result struct {
		Monitoring string `json:"monitoring"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "watch", "owner/repo#7")), &result); err != nil {
		t.Fatal(err)
	}
	if result.Monitoring != "active" {
		t.Fatalf("watch monitoring = %q, want active", result.Monitoring)
	}
}

func TestPRRefreshReportsMonitoring(t *testing.T) {
	stubPRDaemon(t)
	store := setupPRSession(t)
	holdJobsLock(t, store.Root())
	var result struct {
		Monitoring string `json:"monitoring"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh")), &result); err != nil {
		t.Fatal(err)
	}
	if result.Monitoring != "active" {
		t.Fatalf("refresh monitoring = %q, want active", result.Monitoring)
	}
}

func TestPRSessionRequiresManifest(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	for _, args := range [][]string{{"pr", "watch", "o/r#1", "--session", "qm-missing"}, {"pr", "unwatch", "o/r#1", "--session", "qm-missing"}, {"pr", "ls", "--session", "qm-missing"}} {
		cmd := NewRootCmd(WithDeps(store, tmux.NewClient(sessionsRunner())))
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "live manifest") {
			t.Fatalf("%v: err = %v", args, err)
		}
	}
}

func TestPruneDropsOrphanWatchesAndDryRunPreservesRegistry(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	ref, _ := state.ParsePullRequestRef("owner/repo#1")
	if err := store.Create(state.Manifest{SessionID: "qm-orphan"}); err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-orphan", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.Delete("qm-orphan"); err != nil {
		t.Fatal(err)
	}
	writeManifestFile(t, store.Root(), "qm-stale", map[string]any{"session_id": "qm-stale"}, 8*24*time.Hour)
	if _, err := state.WatchPullRequest(store.Root(), "qm-stale", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	path := state.PullRequestsRegistryPath(store.Root())
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(&pruneRunner{sessions: map[string]bool{}})
	dry, err := pruneManifests(t.Context(), store, client, 7, true, testPruneRouter(store, client))
	if err != nil || dry.DroppedWatches != 2 {
		t.Fatalf("dry prune = %#v, %v", dry, err)
	}
	after, err := os.ReadFile(path)
	if err != nil || string(before) != string(after) {
		t.Fatalf("dry run changed registry: %v", err)
	}
	got, err := pruneManifests(t.Context(), store, client, 7, false, testPruneRouter(store, client))
	if err != nil || got.DroppedWatches != 2 {
		t.Fatalf("prune = %#v, %v", got, err)
	}
	prs, err := state.LoadPullRequests(store.Root())
	if err != nil || len(prs) != 0 {
		t.Fatalf("orphan retained: %#v, %v", prs, err)
	}
	if _, err := os.Stat(filepath.Join(store.Root(), "qm-orphan.json")); !os.IsNotExist(err) {
		t.Fatalf("unexpected manifest: %v", err)
	}
}

func TestPRExistingWatchOnUnlistedHostStillWorks(t *testing.T) {
	stubPRDaemon(t)
	store := setupStore(t)
	if err := store.Create(state.Manifest{SessionID: "qm-pr", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}); err != nil {
		t.Fatal(err)
	}
	ref, err := state.ParsePullRequestRef("https://ghe.example/owner/repo/pull/2")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-pr", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	oldHosts := prLoggedInHosts
	t.Cleanup(func() { prLoggedInHosts = oldHosts })
	prLoggedInHosts = func() ([]string, error) {
		t.Error("unwatch, events and refresh must not check gh's hosts")
		return []string{"github.com"}, nil
	}
	const watchRef = "https://ghe.example/owner/repo/pull/2"
	var events []json.RawMessage
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "events", watchRef, "--session", "qm-pr")), &events); err != nil {
		t.Fatalf("events on existing unlisted-host watch: %v", err)
	}
	var refreshed struct {
		PullRequests []state.PullRequest `json:"pull_requests"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "refresh", watchRef, "--session", "qm-pr")), &refreshed); err != nil || len(refreshed.PullRequests) != 1 || refreshed.PullRequests[0].Key != ref.Key {
		t.Fatalf("refresh on existing unlisted-host watch = %#v, %v", refreshed, err)
	}
	var result struct {
		Removed bool `json:"removed"`
	}
	if err := json.Unmarshal([]byte(runCmd(t, store, sessionsRunner(), "pr", "unwatch", watchRef, "--session", "qm-pr")), &result); err != nil || !result.Removed {
		t.Fatalf("unwatch on existing unlisted-host watch = %#v, %v", result, err)
	}
}
