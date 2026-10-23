//go:build linux || darwin

package daemon

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type server struct {
	config          Config
	id, socket, dir string
	lock, jobsLock  *os.File
	listener        net.Listener
	mu              sync.Mutex
	record          Record
	lastActivity    time.Time
	active          int
	stop            chan struct{}
	jobsCancel      context.CancelFunc
	jobsDone        chan struct{}
	jobsRequested   bool
	nextJobsTry     time.Time
}

func setDetached(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }

// Run holds the identity lock for the lifetime of the foreground daemon.
func Run(ctx context.Context, config Config, jobsRequested bool) error {
	config, id, socket, err := config.resolve()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(config.Root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(config.Root, 0o700); err != nil {
		return err
	}
	dir := filepath.Join(config.Root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	if err := os.Chdir(config.Home); err != nil {
		return fmt.Errorf("daemon chdir home: %w", err)
	}
	s := &server{config: config, id: id, socket: socket, dir: dir, stop: make(chan struct{}, 1), lastActivity: time.Now(), jobsRequested: jobsRequested || id == "canonical"}
	if s.config.Jobs == nil {
		s.config.Jobs = []Job{&testJob{root: config.Root}}
	}
	s.lock, err = os.OpenFile(filepath.Join(dir, id+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer s.lock.Close()
	deadline := time.Now().Add(60 * time.Second)
	for {
		err = syscall.Flock(int(s.lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if err != syscall.EWOULDBLOCK {
			return fmt.Errorf("daemon lock: %w", err)
		}
		if Ready(config) == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for daemon lock")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(config.PollInterval):
		}
	}
	s.record.Generation = 1
	if err := s.listen(); err != nil {
		return err
	}
	defer func() {
		if s.listener != nil {
			_ = s.listener.Close()
		}
		if s.jobsLock != nil {
			_ = s.jobsLock.Close()
		}
		_ = os.Remove(s.socket)
		_ = os.Remove(s.recordPath())
	}()
	if err := rotateLog(filepath.Join(dir, id+".log")); err != nil {
		return err
	}
	build, err := fileHash(config.Executable)
	if err != nil {
		return err
	}
	s.record = Record{Running: true, PID: os.Getpid(), Root: config.Root, Identity: id, Socket: socket, Executable: config.Executable, Build: build, Generation: s.record.Generation, Accepting: true}
	if err := s.publish(); err != nil {
		return err
	}
	s.startJobs()
	s.accept()
	ticker := time.NewTicker(config.PollInterval)
	defer ticker.Stop()
	nextLogCheck := time.Now().Add(time.Minute)
	for {
		select {
		case <-ctx.Done():
			return s.shutdown(false)
		case <-s.stop:
			return s.shutdown(false)
		case <-ticker.C:
			if time.Now().After(nextLogCheck) {
				if err := rotateLog(filepath.Join(dir, id+".log")); err != nil {
					fmt.Fprintf(os.Stderr, "daemon log rotation: %v\n", err)
				}
				nextLogCheck = time.Now().Add(time.Minute)
			}
			s.tryJobsLock()
			if time.Since(s.activity()) >= config.IdleGrace && !s.hasWork() && s.clients() == 0 {
				if err := s.shutdown(true); err != nil {
					return err
				}
				if s.listener == nil {
					return nil
				}
			}
		}
	}
}

func (s *server) recordPath() string { return filepath.Join(s.dir, s.id+".json") }

func fileHash(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", h.Sum(nil)), nil
}

func (s *server) publish() error {
	s.mu.Lock()
	record := s.record
	s.mu.Unlock()
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(s.dir, s.id+".json.tmp-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.recordPath())
}

func (s *server) listen() error {
	if info, err := os.Lstat(s.socket); err == nil {
		stat, ok := info.Sys().(*syscall.Stat_t)
		if !ok || info.Mode()&os.ModeSocket == 0 || int(stat.Uid) != os.Getuid() {
			return fmt.Errorf("unsafe stale socket %s", s.socket)
		}
		if conn, err := net.DialTimeout("unix", s.socket, 100*time.Millisecond); err == nil {
			conn.Close()
			return fmt.Errorf("socket already active at %s", s.socket)
		}
		if err := os.Remove(s.socket); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	ln, err := net.Listen("unix", s.socket)
	if err != nil {
		return err
	}
	if u, ok := ln.(*net.UnixListener); ok {
		u.SetUnlinkOnClose(false)
	}
	if err := os.Chmod(s.socket, 0o600); err != nil {
		ln.Close()
		return err
	}
	s.listener = ln
	return nil
}

func (s *server) accept() {
	ln := s.listener
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handle(conn)
		}
	}()
}

func (s *server) handle(conn net.Conn) {
	defer conn.Close()
	s.mu.Lock()
	s.record.Clients++
	h := hello{Root: s.record.Root, Identity: s.id, ProtocolVersion: ProtocolVersion, Generation: s.record.Generation, Accepting: s.record.Accepting}
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.record.Clients--; s.lastActivity = time.Now(); s.mu.Unlock() }()
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	enc := json.NewEncoder(conn)
	if err := enc.Encode(h); err != nil {
		return
	}
	dec := json.NewDecoder(conn)
	for {
		var req request
		if err := dec.Decode(&req); err != nil {
			return
		}
		s.mu.Lock()
		accepting := s.record.Accepting
		if accepting {
			s.active++
		}
		s.mu.Unlock()
		if !accepting {
			_ = enc.Encode(response{Error: "exiting"})
			return
		}
		resp := s.dispatch(req)
		_ = enc.Encode(resp)
		s.mu.Lock()
		s.active--
		s.lastActivity = time.Now()
		s.mu.Unlock()
		if req.Method == "stop" && resp.OK {
			select {
			case s.stop <- struct{}{}:
			default:
			}
			return
		}
	}
}

func (s *server) dispatch(req request) response {
	if req.Method == "check-upgrade" {
		s.probeUpgrade()
		return s.statusResponse()
	}
	if req.ProtocolVersion != ProtocolVersion {
		return response{Error: "incompatible protocol"}
	}
	switch req.Method {
	case "status", "stop":
		return s.statusResponse()
	default:
		if s.config.Handle == nil {
			return response{Error: "unknown method"}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := s.config.Handle(ctx, req.Method); err != nil {
			return response{Error: err.Error()}
		}
		return response{OK: true}
	}
}

func (s *server) statusResponse() response {
	s.mu.Lock()
	record := s.record
	s.mu.Unlock()
	record.HasWork = s.hasWork()
	data, _ := json.Marshal(record)
	return response{OK: true, Data: data}
}

func (s *server) activity() time.Time { s.mu.Lock(); defer s.mu.Unlock(); return s.lastActivity }
func (s *server) clients() int        { s.mu.Lock(); defer s.mu.Unlock(); return s.record.Clients }

func (s *server) shutdown(idle bool) error {
	s.mu.Lock()
	s.record.Accepting = false
	s.mu.Unlock()
	if s.listener != nil {
		_ = s.listener.Close()
		s.listener = nil
	}
	drained := s.quiesceJobs()
	deadline := time.Now().Add(30 * time.Second)
	for {
		s.mu.Lock()
		active := s.active
		s.mu.Unlock()
		if active == 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(s.config.PollInterval)
	}
	if idle && drained && (s.hasWork() || s.clients() > 0) {
		if err := s.listen(); err != nil {
			return err
		}
		s.mu.Lock()
		s.record.Accepting = true
		s.lastActivity = time.Now()
		s.mu.Unlock()
		if err := s.publish(); err != nil {
			return err
		}
		s.startJobs()
		s.accept()
		return nil
	}
	s.stopJobs()
	fmt.Fprintln(os.Stderr, "daemon stopping")
	return nil
}

// SignalContext provides SIGTERM and interrupt handling for the foreground command.
func SignalContext(parent context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
}
