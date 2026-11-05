//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPRJobQuiesceMidFetchKeepsLastStatus(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: "qm-demo"}); err != nil {
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
	job := prstatus.NewJob(root, tmux.NewClient(runtimeTmuxRunner{}), func(ctx context.Context, _, _ string) ([]byte, []byte, error) {
		close(started)
		<-ctx.Done()
		return []byte(`{"data":{"p0":{"pullRequest":{"title":"partial","state":"OPEN"}}}}`), nil, nil
	})
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	s := &server{dir: dir, jobsRequested: true, config: Config{Jobs: []Job{job}, JobDrainTimeout: time.Second}}
	s.tryJobsLock()
	defer s.stopJobs()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("fetch did not start")
	}
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
	runtime := &serve.Server{MutationRunner: mutationRunnerFunc(func(context.Context, []string, []byte) ([]byte, error) {
		close(started)
		<-release
		return []byte("{}"), nil
	})}
	s := &server{config: Config{PollInterval: time.Millisecond, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second}, runtime: runtime, id: "canonical", record: Record{Root: "test", Accepting: true, Generation: 1}}
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
	<-started
	done := make(chan error, 1)
	go func() { done <- s.shutdown(false) }()
	deadline := time.Now().Add(time.Second)
	for {
		s.mu.Lock()
		accepting := s.record.Accepting
		s.mu.Unlock()
		if !accepting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("shutdown did not quiesce")
		}
		time.Sleep(time.Millisecond)
	}
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
	if err := <-done; err != nil {
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
	if err := <-done; err != nil {
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

func TestConnectionSurvivesReadDeadlinesAndPreventsIdleExit(t *testing.T) {
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
	s := &server{config: Config{Root: root, ReadIdleTimeout: 200 * time.Millisecond, WriteTimeout: time.Second, PollInterval: time.Millisecond}, id: "canonical", socket: socket, dir: dir, record: Record{Root: root, Identity: "canonical", Accepting: true}}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if s.listener != nil {
			s.listener.Close()
		}
		os.Remove(socket)
	}()
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	go s.handle(serverConn)
	dec, enc := json.NewDecoder(clientConn), json.NewEncoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 9; i++ {
		time.Sleep(50 * time.Millisecond)
		if err := enc.Encode(request{Method: "status", ProtocolVersion: ProtocolVersion}); err != nil {
			t.Fatal(err)
		}
		var reply response
		if err := dec.Decode(&reply); err != nil || !reply.OK {
			t.Fatalf("request %d: %v %+v", i, err, reply)
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
	select {
	case <-job.restarted:
	case <-time.After(time.Second):
		t.Fatal("job did not restart")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("job did not stop")
	}
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
		time.Sleep(1200 * time.Millisecond)
		data, _ := json.Marshal(Record{Identity: "canonical", UpgradeAvailable: true})
		_ = json.NewEncoder(conn).Encode(response{OK: true, Data: data})
	}()
	record, err := CheckUpgrade(Config{Root: root, Home: home, Executable: "/usr/bin/true"})
	if err != nil || !record.UpgradeAvailable {
		t.Fatalf("probe response after handshake deadline: %+v %v", record, err)
	}
}
