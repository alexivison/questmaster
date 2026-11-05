//go:build linux || darwin

package daemon

import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestExecFailureRestoresDescriptorsAndServing(t *testing.T) {
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
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socket, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	lock, err := os.OpenFile(filepath.Join(dir, "canonical.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	jobs, err := os.OpenFile(filepath.Join(dir, "jobs.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer jobs.Close()
	if err := syscall.Flock(int(jobs.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	var execSawSocket bool
	s := &server{
		config: Config{
			Root:            root,
			PollInterval:    time.Millisecond,
			ReadIdleTimeout: time.Hour,
			WriteTimeout:    time.Second,
			Exec: func(string, []string, []string) error {
				_, err := os.Lstat(socket)
				execSawSocket = err == nil
				return errors.New("forced exec failure")
			},
		},
		id:            "canonical",
		socket:        socket,
		dir:           dir,
		lock:          lock,
		jobsLock:      jobs,
		listener:      listener,
		jobsRequested: true,
		record: Record{
			Running:    true,
			Root:       root,
			Identity:   "canonical",
			Socket:     socket,
			Accepting:  false,
			Jobs:       true,
			Generation: 1,
		},
	}
	s.accept()
	if err := s.reexec("/unused"); err == nil {
		t.Fatal("forced exec failure was hidden")
	}
	if !execSawSocket {
		t.Fatal("reexec removed its inherited socket path")
	}
	if !s.record.Accepting || !s.nextUpgradeTry.After(time.Now()) {
		t.Fatalf("daemon did not resume with backoff: %+v", s.record)
	}
	flags, err := unix.FcntlInt(lock.Fd(), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("lifetime lock leaked into children: flags=%d err=%v", flags, err)
	}
	flags, err = unix.FcntlInt(jobs.Fd(), unix.F_GETFD, 0)
	if err != nil || flags&unix.FD_CLOEXEC == 0 {
		t.Fatalf("jobs lock leaked into children: flags=%d err=%v", flags, err)
	}
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatalf("listener stopped accepting after exec failure: %v", err)
	}
	defer conn.Close()
	dec := json.NewDecoder(conn)
	var greeting hello
	if err := dec.Decode(&greeting); err != nil || !greeting.Accepting {
		t.Fatalf("old daemon did not resume handshake: %+v %v", greeting, err)
	}
	if err := json.NewEncoder(conn).Encode(request{Method: "status", ProtocolVersion: ProtocolVersion}); err != nil {
		t.Fatal(err)
	}
	var reply response
	if err := dec.Decode(&reply); err != nil || !reply.OK {
		t.Fatalf("old daemon did not serve after exec failure: %+v %v", reply, err)
	}
}
