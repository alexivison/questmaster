//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/serve"
)

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

func TestIdleCheckKeepsListenerForArrivingClient(t *testing.T) {
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
	s := &server{config: Config{Root: root, PollInterval: time.Millisecond, ReadIdleTimeout: time.Hour, WriteTimeout: time.Second, Jobs: []Job{job}}, id: "canonical", socket: socket, dir: dir, record: Record{Root: root, Identity: "canonical", Accepting: true, Jobs: true}}
	if err := s.listen(); err != nil {
		t.Fatal(err)
	}
	listener := s.listener
	defer func() { listener.Close(); os.Remove(socket) }()
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
	close(job.continueCheck)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if s.listener != listener {
		t.Fatal("idle resume replaced the live listener")
	}
	resumed, err := net.Dial("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer resumed.Close()
	if err := json.NewDecoder(resumed).Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("resumed handshake: %+v, %v", greeting, err)
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
