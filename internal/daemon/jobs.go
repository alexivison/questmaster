//go:build linux || darwin

package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// jobsRetryInterval is how long a daemon waits after a failed try at jobs.lock.
const jobsRetryInterval = time.Minute

// Monitoring values report whether watched pull requests are polled.
const (
	MonitoringActive      = "active"
	MonitoringUnavailable = "unavailable"
)

// Job reads its work from durable state and runs only under jobs.lock.
type Job interface {
	Name() string
	Run(context.Context) error
	HasWork() bool
}

// jobsLockOwner is what the holder of jobs.lock writes for the next daemon to read.
type jobsLockOwner struct {
	ProtocolVersion int `json:"protocol_version"`
}

func (s *server) hasWork() bool {
	s.mu.Lock()
	runsJobs := s.record.Jobs
	s.mu.Unlock()
	if !runsJobs {
		return false
	}
	for _, job := range s.config.Jobs {
		if job.HasWork() {
			return true
		}
	}
	return false
}

func (s *server) tryJobsLock() {
	if s.jobsCancel != nil {
		return
	}
	if s.jobsLock == nil && !s.takeJobsLock() {
		return
	}
	// Recorded on every start, so a daemon that inherited the lock through a re-exec records its own protocol.
	if err := writeJobsLockOwner(s.jobsLock, s.protocolVersion); err != nil {
		fmt.Fprintf(os.Stderr, "daemon jobs: record owner: %v\n", err)
		s.stopJobs()
		s.nextJobsTry = s.config.now().Add(jobsRetryInterval)
		return
	}
	s.mu.Lock()
	s.record.Jobs = true
	s.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	s.jobsCancel = cancel
	s.jobsDone = make(chan struct{})
	go func() {
		defer close(s.jobsDone)
		var wg sync.WaitGroup
		for _, job := range s.config.Jobs {
			wg.Add(1)
			go func(job Job) { defer wg.Done(); runJob(ctx, job, time.Second) }(job)
		}
		wg.Wait()
	}()
}

// takeJobsLock tries jobs.lock at most once per jobsRetryInterval. It reports whether this daemon now holds it.
func (s *server) takeJobsLock() bool {
	now := s.config.now()
	if now.Before(s.nextJobsTry) {
		return false
	}
	s.nextJobsTry = now.Add(jobsRetryInterval)
	f, err := acquireJobsLock(filepath.Join(s.dir, "jobs.lock"), s.protocolVersion)
	if err != nil {
		fmt.Fprintf(os.Stderr, "daemon jobs: %v\n", err)
		return false
	}
	if f == nil {
		return false
	}
	s.jobsLock = f
	return true
}

// acquireJobsLock returns a nil file and no error while another daemon holds the lock. It refuses,
// with an error, a lock whose last owner speaks a newer protocol: an older binary must not take
// jobs from a newer one. Builds that share a protocol version are not ordered, so they take turns.
func acquireJobsLock(path string, protocolVersion int) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, nil
		}
		return nil, err
	}
	previous, err := readJobsLockOwner(f)
	if err != nil {
		f.Close()
		return nil, err
	}
	if previous.ProtocolVersion > protocolVersion {
		f.Close()
		return nil, fmt.Errorf("not taking jobs: last owner speaks protocol %d, this daemon %d", previous.ProtocolVersion, protocolVersion)
	}
	return f, nil
}

// readJobsLockOwner treats a file with no readable owner record as having no previous owner.
func readJobsLockOwner(f *os.File) (jobsLockOwner, error) {
	var owner jobsLockOwner
	data, err := io.ReadAll(f)
	if err != nil {
		return owner, err
	}
	_ = json.Unmarshal(data, &owner)
	return owner, nil
}

func writeJobsLockOwner(f *os.File, protocolVersion int) error {
	data, err := json.Marshal(jobsLockOwner{ProtocolVersion: protocolVersion})
	if err != nil {
		return err
	}
	if err := f.Truncate(0); err != nil {
		return err
	}
	_, err = f.WriteAt(data, 0)
	return err
}

// PRMonitoring reports whether a daemon on root holds jobs.lock. Watches live in the state root,
// so whichever daemon holds the lock polls them.
func PRMonitoring(root string) (string, error) {
	held, err := jobsLockHeld(filepath.Join(root, "daemon", "jobs.lock"))
	if err != nil {
		return "", err
	}
	if held {
		return MonitoringActive, nil
	}
	return MonitoringUnavailable, nil
}

// jobsLockHeld probes the lock. A free lock is taken for an instant to check it, so a daemon that
// tries in that instant waits one jobsRetryInterval.
func jobsLockHeld(path string) (bool, error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return true, nil
		}
		return false, err
	}
	return false, syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
}

func runJob(ctx context.Context, job Job, backoff time.Duration) {
	for ctx.Err() == nil {
		err := func() (err error) {
			defer func() {
				if value := recover(); value != nil {
					err = fmt.Errorf("panic: %v", value)
				}
			}()
			return job.Run(ctx)
		}()
		if err != nil && ctx.Err() == nil {
			fmt.Fprintf(os.Stderr, "daemon job %s: %v\n", job.Name(), err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < time.Minute {
			backoff *= 2
		}
	}
}

func (s *server) startJobs() { s.tryJobsLock() }

func (s *server) quiesceJobs() bool {
	if s.jobsCancel != nil {
		s.jobsCancel()
	}
	drained := true
	if s.jobsDone != nil {
		timeout := s.config.JobDrainTimeout
		if timeout <= 0 {
			timeout = 10 * time.Second
		}
		select {
		case <-s.jobsDone:
		case <-time.After(timeout):
			drained = false
		}
	}
	if drained {
		s.jobsCancel, s.jobsDone = nil, nil
	}
	return drained
}

func (s *server) stopJobs() {
	if s.jobsLock != nil {
		_ = s.jobsLock.Close()
		s.jobsLock = nil
	}
	s.mu.Lock()
	s.record.Jobs = false
	s.mu.Unlock()
}
