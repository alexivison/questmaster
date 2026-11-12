//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestPRJobQuiesceMidFetchKeepsLastStatus(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{TmuxServer: "questmaster", SessionID: "qm-demo"}); err != nil {
		t.Fatal(err)
	}
	ref, err := state.ParsePullRequestRef("owner/repo#1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(root, "qm-demo", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := state.SavePullRequestStatuses(root, map[string]state.PullRequestStatus{ref.Key: {Title: "last good"}}, nil); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	client := tmux.NewClient(runtimeTmuxRunner{})
	router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client}, func() string { return "questmaster" }, nil)
	job := prstatus.NewJob(root, client, func(ctx context.Context, _, _ string) ([]byte, []byte, error) {
		close(started)
		<-ctx.Done()
		return []byte(`{"data":{"p0":{"pullRequest":{"title":"partial","state":"OPEN"}}}}`), nil, nil
	}, router)
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	s := &server{dir: dir, jobsRequested: true, config: Config{Jobs: []Job{job}, JobDrainTimeout: time.Second}}
	s.tryJobsLock()
	defer s.stopJobs()
	_ = receiveDaemonTestValue(t, started, "PR job fetch to start")
	if !s.quiesceJobs() {
		t.Fatal("fetch did not drain")
	}
	statuses, err := state.LoadPullRequestStatuses(root)
	if err != nil {
		t.Fatal(err)
	}
	if statuses[ref.Key].Title != "last good" {
		t.Fatalf("status changed: %#v", statuses[ref.Key])
	}
}

type mutationRunnerFunc func(context.Context, []string, []byte) ([]byte, error)

func (f mutationRunnerFunc) RunMutationCommand(ctx context.Context, args []string, stdin []byte) ([]byte, error) {
	return f(ctx, args, stdin)
}

func TestShutdownLetsDispatchedRequestFinish(t *testing.T) {
	t.Parallel()
	started := make(chan struct{})
	release := make(chan struct{})
	stoppedAccepting := make(chan struct{})
	runtime := &serve.Server{MutationRunner: mutationRunnerFunc(func(context.Context, []string, []byte) ([]byte, error) {
		close(started)
		<-release
		return []byte("{}"), nil
	})}
	s := &server{
		config:  Config{PollInterval: time.Millisecond, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second},
		runtime: runtime, id: "canonical", record: Record{Root: "test", Accepting: true, Generation: 1},
		onStoppedAccepting: func() { close(stoppedAccepting) },
	}
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	go s.handle(serverConn)
	dec := json.NewDecoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil {
		t.Fatal(err)
	}
	enc := json.NewEncoder(clientConn)
	if err := enc.Encode(request{Method: "start", ProtocolVersion: ProtocolVersion}); err != nil {
		t.Fatal(err)
	}
	_ = receiveDaemonTestValue(t, started, "dispatched mutation to start")
	done := make(chan error, 1)
	go func() { done <- s.shutdown(false) }()
	_ = receiveDaemonTestValue(t, stoppedAccepting, "daemon to stop accepting requests")
	select {
	case <-done:
		t.Fatal("shutdown discarded dispatched work")
	default:
	}
	close(release)
	var reply response
	if err := dec.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if !reply.OK {
		t.Fatalf("dispatched reply: %+v", reply)
	}
	if err := enc.Encode(request{Method: "start", ProtocolVersion: ProtocolVersion}); err != nil {
		t.Fatal(err)
	}
	if err := dec.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if reply.Error != "exiting" {
		t.Fatalf("undispatched reply: %+v", reply)
	}
	if err := receiveDaemonTestValue(t, done, "daemon shutdown to finish"); err != nil {
		t.Fatal(err)
	}
}

type workJob struct{ work bool }

func (j workJob) Name() string                  { return "work" }
func (j workJob) Run(ctx context.Context) error { <-ctx.Done(); return nil }
func (j workJob) HasWork() bool                 { return j.work }

type blockingWorkJob struct {
	checking      chan struct{}
	continueCheck chan struct{}
}

func (j blockingWorkJob) Name() string                  { return "blocking-work" }
func (j blockingWorkJob) Run(ctx context.Context) error { <-ctx.Done(); return nil }
func (j blockingWorkJob) HasWork() bool {
	close(j.checking)
	<-j.continueCheck
	return false
}

func TestIdleCheckRejectsArrivingClientWithoutResuming(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	job := blockingWorkJob{checking: make(chan struct{}), continueCheck: make(chan struct{})}
	activity := time.Unix(1_000, 0)
	s := &server{config: Config{Root: root, PollInterval: time.Millisecond, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second, Jobs: []Job{job}}, id: "canonical", socket: socket, dir: dir, lastActivity: activity, record: Record{Root: root, Identity: "canonical", Accepting: true, Jobs: true}}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	listener := s.listener
	defer func() { listener.Close(); os.Remove(socket) }()
	// A child between fork and exec still holds a copy despite close-on-exec.
	inherited, _, err := duplicateListener(listener.(*net.UnixListener))
	if err != nil {
		t.Fatal(err)
	}
	defer inherited.Close()
	s.accept()
	done := make(chan error, 1)
	go func() { done <- s.shutdown(true) }()
	<-job.checking
	client, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	var greeting hello
	if err := json.NewDecoder(client).Decode(&greeting); err != nil {
		t.Fatal(err)
	}
	if greeting.Accepting {
		t.Fatal("client arriving during idle check was told to use a quiescing daemon")
	}
	if s.clients() != 0 || !s.activity().Equal(activity) {
		t.Fatal("rejected client changed the client count or idle activity")
	}
	close(job.continueCheck)
	if err := receiveDaemonTestValue(t, done, "idle shutdown to finish"); err != nil {
		t.Fatal(err)
	}
	if s.listener != nil {
		t.Fatal("rejected client prevented idle exit")
	}
	if _, err := os.Lstat(socket); !os.IsNotExist(err) {
		t.Fatalf("idle exit left a socket path: %v", err)
	}
	if conn, err := net.Dial("unix", socket); err == nil {
		conn.Close()
		t.Fatal("idle exit left the listener accepting connections")
	}
}

func shutdownTestServer(t *testing.T) *server {
	t.Helper()
	root := t.TempDir()
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		t.Fatal(err)
	}
	s := &server{config: Config{PollInterval: time.Millisecond}, socket: socket}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if s.listener != nil {
			s.listener.Close()
		}
		os.Remove(socket)
	})
	return s
}

func TestShutdownUnlinksSocketBeforeReleasingLock(t *testing.T) {
	t.Parallel()
	s := shutdownTestServer(t)
	lock, err := os.CreateTemp(t.TempDir(), "lock")
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	s.lock = lock
	if err := s.shutdown(false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(s.socket); !os.IsNotExist(err) {
		t.Fatalf("shutdown left socket path: %v", err)
	}
	contender, err := os.Open(lock.Name())
	if err != nil {
		t.Fatal(err)
	}
	defer contender.Close()
	if err := syscall.Flock(int(contender.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
		t.Fatalf("lifetime lock released before shutdown completed: %v", err)
	}
}

func TestShutdownLeavesReplacedSocket(t *testing.T) {
	t.Parallel()
	s := shutdownTestServer(t)
	if err := os.Remove(s.socket); err != nil {
		t.Fatal(err)
	}
	foreign, err := net.Listen("unix", s.socket)
	if err != nil {
		t.Fatal(err)
	}
	defer foreign.Close()
	foreignInfo, err := os.Lstat(s.socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := s.shutdown(false); err != nil {
		t.Fatal(err)
	}
	current, err := os.Lstat(s.socket)
	if err != nil || !os.SameFile(current, foreignInfo) {
		t.Fatalf("shutdown removed replacement socket: %v", err)
	}
	conn, err := net.Dial("unix", s.socket)
	if err != nil {
		t.Fatalf("replacement stopped accepting: %v", err)
	}
	conn.Close()
}

func TestUpgradeQuiesceRejectsClientWithoutCountingIt(t *testing.T) {
	t.Parallel()
	activity := time.Unix(1_000, 0)
	s := &server{config: Config{PollInterval: time.Millisecond, WriteTimeout: time.Second}, id: "canonical", dir: t.TempDir(), upgrade: make(chan string, 1), lastActivity: activity, record: Record{Root: "test", Accepting: true}}
	if !s.beginUpgrade() {
		t.Fatal("upgrade did not begin")
	}
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	if err := clientConn.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	go s.handle(serverConn)
	dec := json.NewDecoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil || greeting.Accepting {
		t.Fatalf("quiescing handshake: %+v, %v", greeting, err)
	}
	if err := dec.Decode(&greeting); err != io.EOF {
		t.Fatalf("rejected connection remained open: %v", err)
	}
	if s.clients() != 0 || !s.activity().Equal(activity) {
		t.Fatal("rejected upgrade client changed the client count or idle activity")
	}
}

func TestOverloadUpgradeSurvivesOverlappingControlConnection(t *testing.T) {
	root := t.TempDir()
	candidate, readyPath, releasePath := gatedUpgradeCandidate(t, root)
	defer func() { _ = os.WriteFile(releasePath, []byte("continue"), 0o600) }()
	s := newOverloadUpgradeServer(t, root, candidate)

	clients := make([]net.Conn, 0, proposedMaxConcurrentConnections)
	defer func() {
		for _, client := range clients {
			_ = client.Close()
		}
	}()
	for i := 0; i < proposedMaxConcurrentConnections-1; i++ {
		conn, err := net.DialTimeout("unix", s.socket, time.Second)
		if err != nil {
			t.Fatalf("open normal connection %d: %v", i, err)
		}
		clients = append(clients, conn)
		_ = conn.SetDeadline(time.Now().Add(time.Second))
		var greeting hello
		if err := json.NewDecoder(conn).Decode(&greeting); err != nil || !greeting.Accepting {
			t.Fatalf("normal connection %d handshake: %+v %v", i, greeting, err)
		}
	}

	upgradeConn, err := net.DialTimeout("unix", s.socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	clients = append(clients, upgradeConn)
	_ = upgradeConn.SetDeadline(time.Now().Add(5 * time.Second))
	upgradeDecoder, upgradeEncoder := json.NewDecoder(upgradeConn), json.NewEncoder(upgradeConn)
	var greeting hello
	if err := upgradeDecoder.Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("upgrade handshake: %+v %v", greeting, err)
	}
	request := serve.Request{ID: json.RawMessage(`"upgrade"`), Method: "check-upgrade", ProtocolVersion: ProtocolVersion}
	if err := upgradeEncoder.Encode(request); err != nil {
		t.Fatal(err)
	}
	waitForDaemonTestFile(t, readyPath)

	statusConn, err := net.DialTimeout("unix", s.socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	clients = append(clients, statusConn)
	_ = statusConn.SetReadDeadline(time.Now().Add(time.Second))
	var statusGreeting hello
	statusErr := json.NewDecoder(statusConn).Decode(&statusGreeting)
	if !errors.Is(statusErr, io.EOF) {
		t.Errorf("overlapping status connection error = %v, want closed connection", statusErr)
	}
	_ = statusConn.Close()

	if err := os.WriteFile(releasePath, []byte("continue"), 0o600); err != nil {
		t.Fatal(err)
	}
	var reply serve.Envelope
	if err := upgradeDecoder.Decode(&reply); err != nil || reply.OK == nil || !*reply.OK || string(reply.ID) != `"upgrade"` {
		t.Fatalf("upgrade response after connection churn: %+v %v", reply, err)
	}
	upgradePath := receiveDaemonTestValue(t, s.upgrade, "upgrade path to be queued")
	if upgradePath != candidate {
		t.Fatalf("queued upgrade path = %q, want %q", upgradePath, candidate)
	}
	if err := s.reexec(upgradePath); err == nil {
		t.Fatal("fake exec should return an error")
	}
	s.mu.Lock()
	accepting, upgrading := s.record.Accepting, s.upgrading
	s.mu.Unlock()
	if !accepting || upgrading {
		t.Fatalf("failed re-exec left daemon accepting=%t upgrading=%t", accepting, upgrading)
	}
}

func TestCheckUpgradeContinuesWhenReplyConnectionCloses(t *testing.T) {
	root := t.TempDir()
	candidate, readyPath, releasePath := gatedUpgradeCandidate(t, root)
	defer func() { _ = os.WriteFile(releasePath, []byte("continue"), 0o600) }()
	s := newOverloadUpgradeServer(t, root, candidate)

	conn, err := net.DialTimeout("unix", s.socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	decoder := json.NewDecoder(conn)
	var greeting hello
	if err := decoder.Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("upgrade handshake: %+v %v", greeting, err)
	}
	if err := json.NewEncoder(conn).Encode(serve.Request{Method: "check-upgrade", ProtocolVersion: ProtocolVersion}); err != nil {
		t.Fatal(err)
	}
	waitForDaemonTestFile(t, readyPath)
	_ = conn.Close()
	if err := os.WriteFile(releasePath, []byte("continue"), 0o600); err != nil {
		t.Fatal(err)
	}
	upgradePath := receiveDaemonTestValue(t, s.upgrade, "upgrade path after reply connection closes")
	if upgradePath != candidate {
		t.Fatalf("queued upgrade path = %q, want %q", upgradePath, candidate)
	}
	if err := s.reexec(upgradePath); err == nil {
		t.Fatal("fake exec should return an error")
	}
	s.mu.Lock()
	accepting, upgrading := s.record.Accepting, s.upgrading
	s.mu.Unlock()
	if !accepting || upgrading {
		t.Fatalf("failed re-exec left daemon accepting=%t upgrading=%t", accepting, upgrading)
	}
}

func gatedUpgradeCandidate(t *testing.T, root string) (candidate, readyPath, releasePath string) {
	t.Helper()
	readyPath = filepath.Join(root, "upgrade-probe-ready")
	releasePath = filepath.Join(root, "upgrade-probe-release")
	t.Setenv("QUESTMASTER_TEST_UPGRADE_READY", readyPath)
	t.Setenv("QUESTMASTER_TEST_UPGRADE_RELEASE", releasePath)
	candidate = filepath.Join(root, "upgrade-candidate")
	script := "#!/bin/sh\n" +
		": > \"$QUESTMASTER_TEST_UPGRADE_READY\"\n" +
		"while [ ! -e \"$QUESTMASTER_TEST_UPGRADE_RELEASE\" ]; do /bin/sleep 0.01; done\n" +
		"printf '{\"protocol_version\":3}\\n'\n"
	if err := os.WriteFile(candidate, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return candidate, readyPath, releasePath
}

func waitForDaemonTestFile(t *testing.T, path string) {
	t.Helper()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	for {
		if _, err := os.Stat(path); err == nil {
			return
		} else if !os.IsNotExist(err) {
			t.Fatal(err)
		}
		select {
		case <-ticker.C:
		case <-timer.C:
			t.Fatalf("timed out waiting for %s", path)
		}
	}
}

func newOverloadUpgradeServer(t *testing.T, root, candidate string) *server {
	t.Helper()
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath(root, "upgrade-test")
	if err != nil {
		t.Fatal(err)
	}
	lock, err := os.OpenFile(filepath.Join(dir, "upgrade-test.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	s := &server{
		config: Config{
			Root: root, Home: root, Executable: candidate,
			ReadIdleTimeout: time.Hour, WriteTimeout: time.Second, PollInterval: time.Millisecond,
			Exec: func(string, []string, []string) error { return io.EOF },
		},
		id: "upgrade-test", socket: socket, dir: dir, lock: lock,
		upgrade: make(chan string, 1),
		record:  Record{Root: root, Identity: "upgrade-test", Build: "old-build", Accepting: true},
	}
	if err := s.listen(); err != nil {
		_ = lock.Close()
		t.Fatal(err)
	}
	s.accept()
	t.Cleanup(func() {
		_ = s.closeListener()
		_ = lock.Close()
	})
	return s
}

func TestIdleExitRechecksClientsAndWork(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name                   string
		clients                int
		work, ownsJobs, resume bool
	}{
		{"client", 1, false, false, true},
		{"work", 0, true, true, true},
		{"unowned-work", 0, true, false, false},
		{"exit", 0, false, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			dir := filepath.Join(root, "daemon")
			if err := os.MkdirAll(dir, 0o700); err != nil {
				t.Fatal(err)
			}
			socket, err := SocketPath(root, "canonical")
			if err != nil {
				t.Fatal(err)
			}
			s := &server{config: Config{Root: root, PollInterval: time.Millisecond, Jobs: []Job{workJob{tc.work}}}, id: "canonical", socket: socket, dir: dir, record: Record{Root: root, Identity: "canonical", Accepting: true, Clients: tc.clients, Jobs: tc.ownsJobs}}
			if err := s.listen(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if s.listener != nil {
					s.listener.Close()
				}
				os.Remove(socket)
			}()
			if tc.name == "client" {
				// A record write failure must not kill a daemon with a live client.
				if err := os.RemoveAll(dir); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.shutdown(true); err != nil {
				t.Fatal(err)
			}
			if (s.listener != nil) != tc.resume {
				t.Fatalf("resume = %t, want %t", s.listener != nil, tc.resume)
			}
			if tc.name == "work" {
				if _, err := os.Lstat(socket); err != nil {
					t.Fatalf("resume removed socket: %v", err)
				}
			} else if !tc.resume {
				if _, err := os.Lstat(socket); !os.IsNotExist(err) {
					t.Fatalf("exit left socket path: %v", err)
				}
			}
		})
	}
}

type deadlineCountingConn struct {
	net.Conn
	mu        sync.Mutex
	deadlines []time.Time
}

func (c *deadlineCountingConn) SetReadDeadline(deadline time.Time) error {
	c.mu.Lock()
	c.deadlines = append(c.deadlines, deadline)
	c.mu.Unlock()
	return c.Conn.SetReadDeadline(deadline)
}

func (c *deadlineCountingConn) readDeadlineValues() []time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]time.Time(nil), c.deadlines...)
}

func TestDaemonConnectionLimitKeepsStatusAvailable(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	s := &server{
		config: Config{Root: root, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second},
		id:     "canonical", socket: socket,
		record: Record{Root: root, Identity: "canonical", Accepting: true},
	}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	s.accept()
	const idleConnectionAttempts = proposedMaxConcurrentConnections + 16
	idle := make([]net.Conn, 0, idleConnectionAttempts)
	defer func() {
		_ = s.closeListener()
		for _, conn := range idle {
			_ = conn.Close()
		}
	}()

	for i := 0; i < idleConnectionAttempts; i++ {
		conn, err := net.DialTimeout("unix", socket, time.Second)
		if err != nil {
			t.Fatalf("open idle connection %d: %v", i, err)
		}
		idle = append(idle, conn)
	}

	statusConn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatalf("open status connection: %v", err)
	}
	defer statusConn.Close()
	if err := statusConn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	dec, enc := json.NewDecoder(statusConn), json.NewEncoder(statusConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("status handshake: %+v %v", greeting, err)
	}
	if err := enc.Encode(serve.Request{Method: "status", ProtocolVersion: ProtocolVersion}); err != nil {
		t.Fatal(err)
	}
	var reply serve.Envelope
	if err := dec.Decode(&reply); err != nil || reply.OK == nil || !*reply.OK || reply.Topic != "status" {
		t.Fatalf("status response: %+v %v", reply, err)
	}
	if clients := s.clients(); clients > proposedMaxConcurrentConnections {
		t.Fatalf("daemon retained %d clients after %d idle connections, want at most %d", clients, len(idle), proposedMaxConcurrentConnections)
	}
}

func TestDaemonRejectsOversizedRequestWithEnvelope(t *testing.T) {
	t.Parallel()
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	s := &server{
		config: Config{ReadIdleTimeout: time.Second, WriteTimeout: time.Second},
		id:     "canonical", record: Record{Root: "test", Accepting: true},
	}
	done := make(chan struct{})
	go func() {
		s.handle(serverConn)
		close(done)
	}()
	if err := clientConn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	dec, enc := json.NewDecoder(clientConn), json.NewEncoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("request handshake: %+v %v", greeting, err)
	}
	if err := enc.Encode(map[string]any{
		"id": "oversized", "method": "status", "protocol_version": ProtocolVersion,
		"data": strings.Repeat("x", proposedMaxRequestBytes+1),
	}); err != nil {
		t.Fatal(err)
	}
	var reply serve.Envelope
	if err := dec.Decode(&reply); err != nil {
		t.Fatal(err)
	}
	if reply.Type != "response" || reply.OK == nil || *reply.OK || reply.Error != "request too large" {
		t.Fatalf("oversized request envelope: %+v", reply)
	}
	clientConn.Close()
	_ = receiveDaemonTestValue(t, done, "oversized request handler to exit")
}

func TestConnectionRenewsReadDeadlineForEachRequestAndPreventsIdleExit(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	clockBase := time.Now()
	var clockTicks atomic.Int64
	s := &server{config: Config{
		Root: root, ReadIdleTimeout: 200 * time.Millisecond, WriteTimeout: time.Second, PollInterval: time.Millisecond,
		Clock: func() time.Time { return clockBase.Add(time.Duration(clockTicks.Add(1)) * time.Second) },
	}, id: "canonical", socket: socket, dir: dir, record: Record{Root: root, Identity: "canonical", Accepting: true}}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if s.listener != nil {
			s.listener.Close()
		}
		os.Remove(socket)
	}()
	serverPipe, clientConn := net.Pipe()
	serverConn := &deadlineCountingConn{Conn: serverPipe}
	defer clientConn.Close()
	go s.handle(serverConn)
	dec, enc := json.NewDecoder(clientConn), json.NewEncoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 9; i++ {
		if err := enc.Encode(request{Method: "status", ProtocolVersion: ProtocolVersion}); err != nil {
			t.Fatal(err)
		}
		var reply response
		if err := dec.Decode(&reply); err != nil || !reply.OK {
			t.Fatalf("request %d: %v %+v", i, err, reply)
		}
	}
	deadlines := serverConn.readDeadlineValues()
	if len(deadlines) < 9 {
		t.Fatalf("read deadlines set = %d, want one for each of 9 requests", len(deadlines))
	}
	for i := 1; i < 9; i++ {
		if !deadlines[i].After(deadlines[i-1]) {
			t.Fatalf("read deadline %d = %s, want it after request %d deadline %s", i+1, deadlines[i], i, deadlines[i-1])
		}
	}
	if s.clients() != 1 {
		t.Fatal("live connection was not counted")
	}
	if err := s.shutdown(true); err != nil {
		t.Fatal(err)
	}
	if s.listener == nil {
		t.Fatal("idle exit ignored the live connection")
	}
}

type panicJob struct {
	runs      atomic.Int32
	restarted chan struct{}
}

func (j *panicJob) Name() string  { return "panic" }
func (j *panicJob) HasWork() bool { return true }
func (j *panicJob) Run(ctx context.Context) error {
	if j.runs.Add(1) == 1 {
		panic("test panic")
	}
	close(j.restarted)
	<-ctx.Done()
	return nil
}

func TestJobRestartsAfterPanic(t *testing.T) {
	t.Parallel()
	job := &panicJob{restarted: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { runJob(ctx, job, time.Millisecond); close(done) }()
	_ = receiveDaemonTestValue(t, job.restarted, "job to restart after panic")
	cancel()
	_ = receiveDaemonTestValue(t, done, "job loop to stop")
	if job.runs.Load() != 2 {
		t.Fatalf("runs = %d", job.runs.Load())
	}
}

func TestTestJobKeepsWorkOnReadErrorWithBackoff(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dir := filepath.Join(root, "daemon", "test-work")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Unix(0, 0)
	job := &testJob{root: root, now: func() time.Time { return now }, retryDelay: time.Minute}
	if !job.HasWork() {
		t.Fatal("read error lost durable work")
	}
	if err := os.Remove(dir); err != nil {
		t.Fatal(err)
	}
	if !job.HasWork() {
		t.Fatal("read error was retried before backoff")
	}
	now = now.Add(time.Minute)
	if job.HasWork() {
		t.Fatal("missing work stayed active after retry")
	}
}

type testJob struct {
	root       string
	mu         sync.Mutex
	now        func() time.Time
	retryDelay time.Duration
	retryAfter time.Time
}

func (j *testJob) HasWork() bool {
	j.mu.Lock()
	defer j.mu.Unlock()
	now := time.Now
	if j.now != nil {
		now = j.now
	}
	if now().Before(j.retryAfter) {
		return true
	}
	info, err := os.Stat(filepath.Join(j.root, "daemon", "test-work"))
	if err == nil && info.IsDir() {
		err = syscall.EISDIR
	}
	if err != nil && !os.IsNotExist(err) {
		delay := j.retryDelay
		if delay <= 0 {
			delay = time.Second
		}
		j.retryAfter = now().Add(delay)
	}
	return err == nil || !os.IsNotExist(err)
}

func TestIdleExitDoesNotResumeWithUndrainedJob(t *testing.T) {
	t.Parallel()
	s := &server{config: Config{JobDrainTimeout: time.Millisecond, PollInterval: time.Millisecond, Jobs: []Job{workJob{work: true}}}, jobsCancel: func() {}, jobsDone: make(chan struct{}), record: Record{Clients: 1, Accepting: true}}
	if err := s.shutdown(true); err != nil {
		t.Fatal(err)
	}
	if s.listener != nil {
		t.Fatal("undrained job resumed alongside a new runner")
	}
}

func TestClientRejectsMismatchedHandshake(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct{ name, root, id string }{
		{"root", "wrong-root", "canonical"},
		{"identity", "", "wrong-id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root, home := t.TempDir(), t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, "daemon"), 0o700); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(home, ".local", "bin", "questmaster")
			if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink("/usr/bin/true", link); err != nil {
				t.Fatal(err)
			}
			socket, err := SocketPath(root, "canonical")
			if err != nil {
				t.Fatal(err)
			}
			ln, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { ln.Close(); os.Remove(socket) }()
			go func() {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				handshakeRoot := tc.root
				if handshakeRoot == "" {
					handshakeRoot = root
				}
				_ = json.NewEncoder(conn).Encode(hello{Root: handshakeRoot, Identity: tc.id, ProtocolVersion: ProtocolVersion, Accepting: true})
			}()
			if err := Ready(Config{Root: root, Home: home, Executable: "/usr/bin/true"}); err == nil {
				t.Fatal("mismatched daemon accepted")
			}
		})
	}
}

func TestCheckUpgradeGetsProbeDeadlineAfterHandshake(t *testing.T) {
	t.Parallel()
	const responseAfterHelloDeadline = 1200 * time.Millisecond // The hello deadline is one second; the follow-up probe must still work.
	root, home := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "daemon"), 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("/usr/bin/true", link); err != nil {
		t.Fatal(err)
	}
	socket, err := SocketPath(root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { ln.Close(); os.Remove(socket) }()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = json.NewEncoder(conn).Encode(hello{Root: root, Identity: "canonical", ProtocolVersion: ProtocolVersion, Accepting: true})
		var req request
		if json.NewDecoder(conn).Decode(&req) != nil {
			return
		}
		time.Sleep(responseAfterHelloDeadline)
		data, _ := json.Marshal(Record{Identity: "canonical", UpgradeAvailable: true})
		_ = json.NewEncoder(conn).Encode(response{OK: true, Data: data})
	}()
	record, err := CheckUpgrade(Config{Root: root, Home: home, Executable: "/usr/bin/true"})
	if err != nil || !record.UpgradeAvailable {
		t.Fatalf("probe response after handshake deadline: %+v %v", record, err)
	}
}
