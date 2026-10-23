//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestShutdownLetsDispatchedRequestFinish(t *testing.T) {
	t.Parallel()
	started := make(chan struct{})
	release := make(chan struct{})
	s := &server{config: Config{PollInterval: time.Millisecond, Handle: func(context.Context, string) error {
		close(started)
		<-release
		return nil
	}}, id: "canonical", record: Record{Root: "test", Accepting: true, Generation: 1}}
	serverConn, clientConn := net.Pipe()
	defer clientConn.Close()
	go s.handle(serverConn)
	dec := json.NewDecoder(clientConn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil {
		t.Fatal(err)
	}
	enc := json.NewEncoder(clientConn)
	if err := enc.Encode(request{Method: "hold", ProtocolVersion: ProtocolVersion}); err != nil {
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
	if err := enc.Encode(request{Method: "hold", ProtocolVersion: ProtocolVersion}); err != nil {
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

func TestIdleExitRechecksClientsAndWork(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name         string
		clients      int
		work, resume bool
	}{
		{"client", 1, false, true},
		{"work", 0, true, true},
		{"exit", 0, false, false},
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
			s := &server{config: Config{Root: root, PollInterval: time.Millisecond, Jobs: []Job{workJob{tc.work}}}, id: "canonical", socket: socket, dir: dir, record: Record{Root: root, Identity: "canonical", Accepting: true, Clients: tc.clients}}
			if err := s.listen(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if s.listener != nil {
					s.listener.Close()
				}
				os.Remove(socket)
			}()
			if err := s.shutdown(true); err != nil {
				t.Fatal(err)
			}
			if (s.listener != nil) != tc.resume {
				t.Fatalf("resume = %t, want %t", s.listener != nil, tc.resume)
			}
		})
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
