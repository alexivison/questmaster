//go:build linux || darwin

package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// probeUpgrade is version-independent and runs only on an explicit nudge.
func (s *server) probeUpgrade() string {
	s.mu.Lock()
	currentBuild := s.record.Build
	s.record.UpgradeAvailable = false
	backingOff := time.Now().Before(s.nextUpgradeTry)
	s.mu.Unlock()
	if backingOff {
		return ""
	}
	path := s.config.Executable
	if s.id == "canonical" {
		var err error
		path, err = filepath.EvalSymlinks(filepath.Join(s.config.Home, ".local", "bin", "questmaster"))
		if err != nil {
			return ""
		}
	}
	first, err := os.Stat(path)
	if err != nil || !first.Mode().IsRegular() || first.Mode().Perm()&0o111 == 0 {
		return ""
	}
	second, err := os.Stat(path)
	if err != nil || !os.SameFile(first, second) || first.Size() != second.Size() || !first.ModTime().Equal(second.ModTime()) {
		return ""
	}
	build, err := fileHash(path)
	if err != nil || build == currentBuild {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, "version", "--json")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = time.Second
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		return ""
	}
	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		case <-done:
		}
	}()
	err = cmd.Wait()
	close(done)
	if err != nil {
		return ""
	}
	var version struct {
		ProtocolVersion int `json:"protocol_version"`
	}
	if json.Unmarshal(out.Bytes(), &version) != nil || version.ProtocolVersion < 1 {
		return ""
	}
	third, err := os.Stat(path)
	if err != nil || !os.SameFile(second, third) || third.Size() != second.Size() || !third.ModTime().Equal(second.ModTime()) {
		return ""
	}
	if s.id == "canonical" {
		current, err := filepath.EvalSymlinks(filepath.Join(s.config.Home, ".local", "bin", "questmaster"))
		if err != nil || current != path {
			return ""
		}
	}
	s.mu.Lock()
	s.record.UpgradeAvailable = true
	s.mu.Unlock()
	return path
}

func (s *server) beginUpgrade() bool {
	s.mu.Lock()
	if s.upgrading || !s.record.Accepting || s.upgrade == nil {
		s.mu.Unlock()
		return false
	}
	s.upgrading = true
	s.record.Accepting = false
	s.mu.Unlock()
	deadline := time.Now().Add(30 * time.Second)
	for {
		s.mu.Lock()
		active := s.active
		s.mu.Unlock()
		if active <= 1 {
			break
		}
		if time.Now().After(deadline) {
			s.resumeUpgrade()
			return false
		}
		time.Sleep(s.config.PollInterval)
	}
	if err := s.publish(); err != nil {
		fmt.Fprintf(os.Stderr, "daemon upgrade publish: %v\n", err)
		s.resumeUpgrade()
		return false
	}
	return true
}

var errJobsNotDrained = errors.New("jobs did not drain before upgrade")
var errRestoreDescriptors = errors.New("could not restore close-on-exec")

func (s *server) reexec(path string) error {
	if !s.quiesceJobs() {
		return errJobsNotDrained
	}
	resume := true
	defer func() {
		if resume { // A successful Exec never returns.
			s.resumeUpgrade()
		}
	}()
	listener, ok := s.listener.(*net.UnixListener)
	if !ok {
		return errors.New("upgrade listener is not a unix socket")
	}
	listenerFile, listenerFD, err := duplicateListener(listener)
	if err != nil {
		return err
	}
	defer listenerFile.Close()
	h := handoff{Root: s.config.Root, Identity: s.id, Generation: s.record.Generation, LockFD: int(s.lock.Fd()), ListenerFD: listenerFD}
	if s.jobsLock != nil {
		h.JobsFD = int(s.jobsLock.Fd())
	}
	value, err := json.Marshal(h)
	if err != nil {
		return err
	}
	fds := []int{h.LockFD, h.ListenerFD}
	if h.JobsFD != 0 {
		fds = append(fds, h.JobsFD)
	}
	syscall.ForkLock.Lock()
	for _, fd := range fds {
		if err = setCloseOnExec(fd, false); err != nil {
			break
		}
	}
	if err == nil {
		execFn := s.config.Exec
		if execFn == nil {
			execFn = syscall.Exec
		}
		args := append([]string{path}, os.Args[1:]...)
		err = execFn(path, args, append(os.Environ(), handoffEnv+"="+string(value)))
	}
	var restoreError error
	for _, fd := range fds {
		if fdErr := setCloseOnExec(fd, true); fdErr != nil {
			fmt.Fprintf(os.Stderr, "daemon restore close-on-exec fd %d: %v\n", fd, fdErr)
			restoreError = errors.Join(restoreError, fdErr)
		}
	}
	syscall.ForkLock.Unlock()
	if restoreError != nil {
		resume = false
		return fmt.Errorf("%w: %v", errRestoreDescriptors, restoreError)
	}
	return fmt.Errorf("exec replacement: %w", err)
}

func duplicateListener(listener *net.UnixListener) (*os.File, int, error) {
	raw, err := listener.SyscallConn()
	if err != nil {
		return nil, 0, err
	}
	var fd int
	if err := raw.Control(func(original uintptr) {
		fd, err = unix.FcntlInt(original, unix.F_DUPFD_CLOEXEC, 0)
	}); err != nil {
		return nil, 0, err
	}
	if err != nil {
		return nil, 0, err
	}
	return os.NewFile(uintptr(fd), "handoff-listener"), fd, nil
}

func (s *server) resumeUpgrade() {
	s.mu.Lock()
	s.record.Accepting = true
	s.record.UpgradeAvailable = false
	s.upgrading = false
	s.nextUpgradeTry = time.Now().Add(time.Minute)
	s.lastActivity = time.Now()
	s.mu.Unlock()
	s.startJobs()
	if err := s.publish(); err != nil {
		fmt.Fprintf(os.Stderr, "daemon resume publish: %v\n", err)
	}
}

func setCloseOnExec(fd int, closeOnExec bool) error {
	flags, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0)
	if err != nil {
		return err
	}
	if closeOnExec {
		flags |= unix.FD_CLOEXEC
	} else {
		flags &^= unix.FD_CLOEXEC
	}
	_, err = unix.FcntlInt(uintptr(fd), unix.F_SETFD, flags)
	return err
}
