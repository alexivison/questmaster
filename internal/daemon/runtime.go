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

	"github.com/alexivison/questmaster/internal/prstatus"
	"github.com/alexivison/questmaster/internal/serve"
	"github.com/alexivison/questmaster/internal/state"
)

type server struct {
	config          Config
	id, socket, dir string
	lock, jobsLock  *os.File
	listener        net.Listener
	socketInfo      os.FileInfo
	mu              sync.Mutex
	record          Record
	lastActivity    time.Time
	active          int
	stop            chan struct{}
	upgrade         chan string
	upgrading       bool
	nextUpgradeTry  time.Time
	runtime         *serve.Server
	sourceMu        sync.Mutex
	source          serve.ChangeSource
	sourceClients   int
	jobsCancel      context.CancelFunc
	jobsDone        chan struct{}
	jobsRequested   bool
	nextJobsTry     time.Time
}

func setDetached(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} }

// Run holds the identity lock for the lifetime of the foreground daemon.
func Run(ctx context.Context, config Config, jobsRequested bool) error {
	h, handoffErr := takeHandoff()
	if handoffErr != nil {
		fmt.Fprintf(os.Stderr, "daemon handoff: %v\n", handoffErr)
		if h != nil {
			for _, fd := range []int{h.LockFD, h.JobsFD, h.ListenerFD} {
				if fd != 0 {
					_ = syscall.Close(fd)
				}
			}
			h = nil
		}
	}
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
	if err := writeShims(config.Root, id, config.Executable); err != nil {
		return fmt.Errorf("daemon shims: %w", err)
	}
	if err := installEnvironment(config.daemonEnvironment(id)); err != nil {
		return fmt.Errorf("daemon environment: %w", err)
	}
	s := &server{config: config, id: id, socket: socket, dir: dir, stop: make(chan struct{}, 1), upgrade: make(chan string, 1), lastActivity: time.Now(), jobsRequested: jobsRequested || id == "canonical"}
	s.runtime = config.Runtime
	if s.runtime == nil {
		s.runtime = &serve.Server{Snapshotter: serve.NewSnapshotter(state.OpenStore(config.Root), nil, nil)}
	}
	if s.runtime.Snapshotter == nil {
		s.runtime.Snapshotter = serve.NewSnapshotter(state.OpenStore(config.Root), nil, nil)
	}
	for _, job := range config.Jobs {
		if pr, ok := job.(*prstatus.Job); ok {
			s.runtime.PRRefresh = func(ctx context.Context, keys []string, wait bool) (map[string]prstatus.HostResult, error) {
				if !s.jobsOwner() {
					return nil, fmt.Errorf("PR polling is unavailable on this daemon")
				}
				if !wait {
					pr.Notify(keys)
					return map[string]prstatus.HostResult{}, nil
				}
				return pr.Refresh(ctx, keys)
			}
			break
		}
	}
	if config.ClockInterval > 0 {
		s.runtime.ClockInterval = config.ClockInterval
	}
	if h != nil {
		if err := s.adopt(*h); err != nil {
			fmt.Fprintf(os.Stderr, "daemon adoption: %v; starting normally\n", err)
		}
	}
	if s.lock == nil {
		s.lock, err = os.OpenFile(filepath.Join(dir, id+".lock"), os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return err
		}
		deadline := time.Now().Add(60 * time.Second)
		for {
			err = syscall.Flock(int(s.lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
			if err == nil {
				break
			}
			if err != syscall.EWOULDBLOCK {
				s.lock.Close()
				return fmt.Errorf("daemon lock: %w", err)
			}
			if Ready(config) == nil {
				s.lock.Close()
				return nil
			}
			if time.Now().After(deadline) {
				s.lock.Close()
				return errors.New("timed out waiting for daemon lock")
			}
			select {
			case <-ctx.Done():
				s.lock.Close()
				return ctx.Err()
			case <-time.After(config.PollInterval):
			}
		}
		s.record.Generation = 1
		if err := s.listen(); err != nil {
			s.lock.Close()
			return err
		}
	}
	defer s.lock.Close()
	defer func() {
		_ = s.closeListener()
		if s.jobsLock != nil {
			_ = s.jobsLock.Close()
		}
		_ = os.Remove(s.recordPath())
	}()
	if err := rotateLog(filepath.Join(dir, id+".log")); err != nil {
		return err
	}
	build, err := fileHash(config.Executable)
	if err != nil {
		return err
	}
	s.record = Record{Running: true, PID: os.Getpid(), Root: config.Root, Identity: id, Socket: socket, Executable: config.Executable, ShimDirectory: filepath.Join(config.Root, "daemon", "bin", id), Build: build, Generation: s.record.Generation, Jobs: s.jobsLock != nil, Accepting: true}
	if err := s.publish(); err != nil {
		return err
	}
	s.startJobs()
	s.accept()
	ticker := time.NewTicker(config.PollInterval)
	defer ticker.Stop()
	nextLogCheck := time.Now().Add(time.Minute)
	nextWorkCheck := time.Time{}
	for {
		select {
		case <-ctx.Done():
			return s.shutdown(false)
		case <-s.stop:
			return s.shutdown(false)
		case path := <-s.upgrade:
			if err := s.reexec(path); err != nil {
				fmt.Fprintf(os.Stderr, "daemon upgrade: %v\n", err)
				if errors.Is(err, errJobsNotDrained) || errors.Is(err, errRestoreDescriptors) {
					return err
				}
			}
		case <-ticker.C:
			if time.Now().After(nextLogCheck) {
				if err := rotateLog(filepath.Join(dir, id+".log")); err != nil {
					fmt.Fprintf(os.Stderr, "daemon log rotation: %v\n", err)
				}
				nextLogCheck = time.Now().Add(time.Minute)
			}
			s.tryJobsLock()
			if time.Since(s.activity()) >= config.IdleGrace && s.clients() == 0 && !time.Now().Before(nextWorkCheck) {
				nextWorkCheck = time.Now().Add(time.Second)
				if s.hasWork() {
					continue
				}
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
		// Reexec hands this listener to a new image at the same socket path.
		u.SetUnlinkOnClose(false)
	}
	if err := os.Chmod(s.socket, 0o600); err != nil {
		ln.Close()
		return err
	}
	info, err := os.Lstat(s.socket)
	if err != nil {
		ln.Close()
		return err
	}
	s.socketInfo = info
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
	h := hello{Root: s.record.Root, Identity: s.id, ProtocolVersion: ProtocolVersion, Generation: s.record.Generation, Accepting: s.record.Accepting}
	if h.Accepting {
		s.record.Clients++
	}
	s.mu.Unlock()
	if h.Accepting {
		defer func() { s.mu.Lock(); s.record.Clients--; s.lastActivity = time.Now(); s.mu.Unlock() }()
	}
	enc := json.NewEncoder(conn)
	_ = conn.SetWriteDeadline(time.Now().Add(s.config.WriteTimeout))
	if err := enc.Encode(h); err != nil || !h.Accepting {
		return
	}
	dec := json.NewDecoder(conn)
	for {
		var req serve.Request
		_ = conn.SetReadDeadline(time.Now().Add(s.config.ReadIdleTimeout))
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
			_ = conn.SetWriteDeadline(time.Now().Add(s.config.WriteTimeout))
			_ = serve.WriteEnvelope(enc, daemonError(req, "exiting"))
			return
		}
		resp, upgradePath := s.dispatch(req)
		var source serve.ChangeSource
		var release func()
		if req.Method == "subscribe" && resp.OK != nil && *resp.OK {
			var err error
			source, release, err = s.subscribeSource()
			if err != nil {
				resp = daemonError(req, err.Error())
			}
		}
		_ = conn.SetWriteDeadline(time.Now().Add(s.config.WriteTimeout))
		writeErr := serve.WriteEnvelope(enc, resp)
		s.mu.Lock()
		s.active--
		s.lastActivity = time.Now()
		s.mu.Unlock()
		if writeErr != nil {
			if release != nil {
				release()
			}
			return
		}
		if source != nil {
			_ = conn.SetReadDeadline(time.Time{})
			_ = conn.SetWriteDeadline(time.Time{})
			ctx, cancel := context.WithCancel(context.Background())
			go func() {
				var buf [1]byte
				_, _ = conn.Read(buf[:])
				cancel()
			}()
			_ = s.runtime.Subscribe(ctx, enc, req, source)
			cancel()
			release()
			return
		}
		if upgradePath != "" {
			s.upgrade <- upgradePath
			return
		}
		if req.Method == "stop" && resp.OK != nil && *resp.OK {
			select {
			case s.stop <- struct{}{}:
			default:
			}
			return
		}
	}
}

func (s *server) dispatch(req serve.Request) (serve.Envelope, string) {
	if req.Method == "check-upgrade" {
		path := s.probeUpgrade()
		if path != "" && s.beginUpgrade() {
			return s.statusResponse(req, true), path
		}
		return s.statusResponse(req, false), ""
	}
	if req.ProtocolVersion != 0 && req.ProtocolVersion != ProtocolVersion {
		return daemonError(req, "incompatible protocol"), ""
	}
	switch req.Method {
	case "status", "stop":
		return s.statusResponse(req, false), ""
	default:
		return s.runtime.HandleRequest(context.Background(), req), ""
	}
}

func (s *server) jobsOwner() bool { s.mu.Lock(); defer s.mu.Unlock(); return s.record.Jobs }

func daemonError(req serve.Request, message string) serve.Envelope {
	ok := false
	return serve.Envelope{Type: "response", ID: req.ID, OK: &ok, Error: message}
}

func (s *server) statusResponse(req serve.Request, upgradeStarted bool) serve.Envelope {
	s.mu.Lock()
	record := s.record
	s.mu.Unlock()
	record.HasWork = s.hasWork()
	record.UpgradeStarted = upgradeStarted
	ok := true
	return serve.Envelope{Type: "response", ID: req.ID, OK: &ok, Topic: req.Method, Data: record}
}

func (s *server) subscribeSource() (serve.ChangeSource, func(), error) {
	s.sourceMu.Lock()
	defer s.sourceMu.Unlock()
	if s.source == nil {
		if s.runtime.ChangeSource != nil {
			s.source = s.runtime.ChangeSource
		} else {
			interval := s.runtime.ClockInterval
			if interval <= 0 {
				interval = time.Second
			}
			source, err := serve.NewFileChangeSource(context.Background(), s.runtime.Snapshotter, interval)
			if err != nil {
				return nil, nil, err
			}
			s.source = source
		}
	}
	s.sourceClients++
	return s.source, func() {
		s.sourceMu.Lock()
		defer s.sourceMu.Unlock()
		s.sourceClients--
		if s.sourceClients == 0 && s.runtime.ChangeSource == nil {
			_ = s.source.Close()
			s.source = nil
		}
	}, nil
}

func (s *server) activity() time.Time { s.mu.Lock(); defer s.mu.Unlock(); return s.lastActivity }
func (s *server) clients() int        { s.mu.Lock(); defer s.mu.Unlock(); return s.record.Clients }

func (s *server) closeListener() error {
	var closeErr error
	if s.listener != nil {
		closeErr = s.listener.Close()
		s.listener = nil
	}
	if s.socketInfo == nil {
		return closeErr
	}
	info, err := os.Lstat(s.socket)
	if os.IsNotExist(err) {
		return closeErr
	}
	if err != nil {
		return errors.Join(closeErr, err)
	}
	if !os.SameFile(info, s.socketInfo) {
		return closeErr
	}
	// A forked child may briefly keep the listener alive before exec closes its inherited fd.
	if err := os.Remove(s.socket); err != nil && !os.IsNotExist(err) {
		return errors.Join(closeErr, err)
	}
	return closeErr
}

func (s *server) shutdown(idle bool) error {
	s.mu.Lock()
	s.record.Accepting = false
	s.mu.Unlock()
	if !idle {
		if err := s.closeListener(); err != nil {
			return err
		}
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
		s.mu.Lock()
		s.record.Accepting = true
		s.lastActivity = time.Now()
		s.mu.Unlock()
		if err := s.publish(); err != nil {
			fmt.Fprintf(os.Stderr, "daemon resume record: %v\n", err)
		}
		s.startJobs()
		return nil
	}
	if err := s.closeListener(); err != nil {
		return err
	}
	s.stopJobs()
	fmt.Fprintln(os.Stderr, "daemon stopping")
	return nil
}

// SignalContext provides SIGTERM and interrupt handling for the foreground command.
func SignalContext(parent context.Context) (context.Context, context.CancelFunc) {
	return signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
}
