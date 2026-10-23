//go:build linux || darwin

package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"

	"golang.org/x/sys/unix"
)

const handoffEnv = "QUESTMASTER_DAEMON_HANDOFF"

type handoff struct {
	Root       string `json:"root"`
	Identity   string `json:"identity"`
	Generation int    `json:"generation"`
	LockFD     int    `json:"lock_fd"`
	JobsFD     int    `json:"jobs_fd"`
	ListenerFD int    `json:"listener_fd"`
}

// takeHandoff closes the inheritance window before resolving identity or starting children.
func takeHandoff() (*handoff, error) {
	value, present := os.LookupEnv(handoffEnv)
	if !present {
		return nil, nil
	}
	_ = os.Unsetenv(handoffEnv)
	var h handoff
	if err := json.Unmarshal([]byte(value), &h); err != nil {
		return nil, err
	}
	if h.LockFD < 3 || h.ListenerFD < 3 || h.LockFD == h.ListenerFD || h.JobsFD != 0 && (h.JobsFD < 3 || h.JobsFD == h.LockFD || h.JobsFD == h.ListenerFD) {
		return nil, errors.New("invalid handoff descriptors")
	}
	for _, fd := range []int{h.LockFD, h.ListenerFD, h.JobsFD} {
		if fd != 0 {
			if err := setCloseOnExec(fd, true); err != nil {
				return &h, fmt.Errorf("set close-on-exec on fd %d: %w", fd, err)
			}
		}
	}
	return &h, nil
}

func (s *server) adopt(h handoff) (err error) {
	lock := os.NewFile(uintptr(h.LockFD), "inherited-lifetime-lock")
	listenerFile := os.NewFile(uintptr(h.ListenerFD), "inherited-listener")
	var jobs *os.File
	if h.JobsFD != 0 {
		jobs = os.NewFile(uintptr(h.JobsFD), "inherited-jobs-lock")
	}
	defer func() {
		listenerFile.Close()
		if err != nil {
			lock.Close()
			if jobs != nil {
				jobs.Close()
			}
		}
	}()
	if h.Root != s.config.Root || h.Identity != s.id || h.Generation < 1 {
		return errors.New("handoff identity mismatch")
	}
	if jobs != nil && !s.jobsRequested {
		return errors.New("unexpected jobs lock")
	}
	if err := verifyHandoffFile(lock, filepath.Join(s.dir, s.id+".lock")); err != nil {
		return fmt.Errorf("lifetime lock: %w", err)
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("lifetime lock not held: %w", err)
	}
	if jobs != nil {
		if err := verifyHandoffFile(jobs, filepath.Join(s.dir, "jobs.lock")); err != nil {
			return fmt.Errorf("jobs lock: %w", err)
		}
		if err := syscall.Flock(int(jobs.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			return fmt.Errorf("jobs lock not held: %w", err)
		}
	}
	if err := verifyHandoffListener(listenerFile, s.socket); err != nil {
		return fmt.Errorf("listener: %w", err)
	}
	listener, err := net.FileListener(listenerFile)
	if err != nil {
		return err
	}
	unixListener, ok := listener.(*net.UnixListener)
	if !ok {
		listener.Close()
		return errors.New("inherited listener is not unix")
	}
	unixListener.SetUnlinkOnClose(false)
	s.lock, s.jobsLock, s.listener = lock, jobs, unixListener
	s.record.Generation = h.Generation + 1
	return nil
}

func verifyHandoffFile(file *os.File, path string) error {
	inherited, err := file.Stat()
	if err != nil {
		return err
	}
	current, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !os.SameFile(inherited, current) {
		return errors.New("inode does not match path")
	}
	if !inherited.Mode().IsRegular() {
		return errors.New("wrong file type")
	}
	return nil
}

func verifyHandoffListener(file *os.File, path string) error {
	inherited, err := file.Stat()
	if err != nil {
		return err
	}
	current, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if inherited.Mode()&os.ModeSocket == 0 || current.Mode()&os.ModeSocket == 0 {
		return errors.New("wrong socket type")
	}
	owner, ok := current.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return errors.New("socket owner mismatch")
	}
	address, err := unix.Getsockname(int(file.Fd()))
	if err != nil {
		return err
	}
	unixAddress, ok := address.(*unix.SockaddrUnix)
	if !ok || unixAddress.Name != path {
		return errors.New("socket path mismatch")
	}
	return nil
}
