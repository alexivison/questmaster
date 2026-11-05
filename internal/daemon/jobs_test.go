//go:build linux || darwin

package daemon

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

// fakeJob runs until its context is cancelled and counts its starts.
type fakeJob struct {
	started chan struct{}
	runs    atomic.Int32
}

func newFakeJob() *fakeJob { return &fakeJob{started: make(chan struct{}, 1)} }

func (j *fakeJob) Name() string  { return "fake" }
func (j *fakeJob) HasWork() bool { return false }

func (j *fakeJob) Run(ctx context.Context) error {
	j.runs.Add(1)
	select {
	case j.started <- struct{}{}:
	default:
	}
	<-ctx.Done()
	return nil
}

func waitForJobStart(t *testing.T, job *fakeJob) {
	t.Helper()
	select {
	case <-job.started:
	case <-time.After(time.Second):
		t.Fatal("job did not start")
	}
}

// newJobsServer builds a daemon on dir with an injected clock. jobsFlag is the --jobs value, so the
// gate is the same one Run applies.
func newJobsServer(dir, id string, clock *fakeClock, job Job, jobsFlag bool) *server {
	return &server{
		dir: dir, id: id, jobsRequested: jobsAllowed(id, jobsFlag),
		config: Config{Jobs: []Job{job}, JobDrainTimeout: time.Second, Clock: clock.Now},
	}
}

func stopJobsServer(s *server) {
	s.quiesceJobs()
	s.stopJobs()
}

func TestOneJobsOwnerRunsAndTheOtherTakesOverWithinARetryWindow(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	jobA, jobB := newFakeJob(), newFakeJob()
	a := newJobsServer(dir, "bin-a0000000000000000", clock, jobA, false)
	b := newJobsServer(dir, "bin-b0000000000000000", clock, jobB, false)

	a.tryJobsLock()
	waitForJobStart(t, jobA)
	defer stopJobsServer(a)
	defer stopJobsServer(b)
	for range 3 {
		clock.Advance(jobsRetryInterval)
		b.tryJobsLock()
	}
	if jobB.runs.Load() != 0 || b.jobsLock != nil {
		t.Fatal("second daemon ran jobs while the first holds the lock")
	}

	releasedAt := clock.Now()
	stopJobsServer(a)
	var tookAt time.Time
	for range int(2 * jobsRetryInterval / time.Second) {
		clock.Advance(time.Second)
		b.tryJobsLock()
		if b.jobsLock != nil {
			tookAt = clock.Now()
			break
		}
	}
	if tookAt.IsZero() {
		t.Fatal("second daemon did not take over")
	}
	if took := tookAt.Sub(releasedAt); took > jobsRetryInterval {
		t.Fatalf("took over %s after the first stopped, want within %s", took, jobsRetryInterval)
	}
	waitForJobStart(t, jobB)
}

func TestOnlyInstalledIdentitiesTakeJobsWithoutTheFlag(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		id   string
		flag bool
		want bool
	}{
		{"canonical", false, true},
		{"bin-0123456789abcdef", false, true},
		{"dev-0123456789abcdef", false, false},
		{"dev-0123456789abcdef", true, true},
	} {
		if got := jobsAllowed(tc.id, tc.flag); got != tc.want {
			t.Fatalf("jobsAllowed(%s, flag=%v) = %v, want %v", tc.id, tc.flag, got, tc.want)
		}
	}
}

func TestDevDaemonRunsJobsOnlyWhenStartedWithJobsFlag(t *testing.T) {
	t.Parallel()
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	job := newFakeJob()
	s := newJobsServer(t.TempDir(), "dev-0123456789abcdef", clock, job, false)
	defer stopJobsServer(s)
	s.tryJobsLock()
	if s.jobsLock != nil {
		t.Fatal("development daemon took jobs.lock without --jobs")
	}
	select {
	case <-job.started:
		t.Fatal("development daemon ran a job without --jobs")
	case <-time.After(100 * time.Millisecond):
	}

	withFlag := newFakeJob()
	flagged := newJobsServer(t.TempDir(), "dev-fedcba9876543210", clock, withFlag, true)
	defer stopJobsServer(flagged)
	flagged.tryJobsLock()
	waitForJobStart(t, withFlag)
}

func TestGoInstallDaemonRunsJobsWithoutTheFlag(t *testing.T) {
	t.Parallel()
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	job := newFakeJob()
	// A go install binary gets a bin- identity; it owns jobs like the installed app does.
	s := newJobsServer(t.TempDir(), "bin-0123456789abcdef", clock, job, false)
	defer stopJobsServer(s)
	s.tryJobsLock()
	waitForJobStart(t, job)
}

func TestPRMonitoringReportsWhetherAJobsOwnerHoldsTheLock(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	dir := filepath.Join(root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	want := func(state string) {
		t.Helper()
		got, err := PRMonitoring(root)
		if err != nil || got != state {
			t.Fatalf("PRMonitoring = %q, %v; want %q", got, err, state)
		}
	}
	want(MonitoringUnavailable)

	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	job := newFakeJob()
	owner := newJobsServer(dir, "bin-0123456789abcdef", clock, job, false)
	owner.tryJobsLock()
	waitForJobStart(t, job)
	want(MonitoringActive)

	stopJobsServer(owner)
	want(MonitoringUnavailable)
}
