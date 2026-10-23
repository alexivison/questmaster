//go:build linux || darwin

package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

// Job reads its work from durable state and runs only under jobs.lock.
type Job interface {
	Name() string
	Run(context.Context) error
	HasWork() bool
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
	if !s.jobsRequested || s.jobsCancel != nil {
		return
	}
	if s.jobsLock == nil {
		if time.Now().Before(s.nextJobsTry) {
			return
		}
		s.nextJobsTry = time.Now().Add(time.Minute)
		f, err := os.OpenFile(filepath.Join(s.dir, "jobs.lock"), os.O_CREATE|os.O_RDWR, 0o600)
		if err != nil {
			return
		}
		if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			f.Close()
			return
		}
		s.jobsLock = f
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
