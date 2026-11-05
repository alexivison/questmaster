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

// newJobsServer builds a daemon on dir with an injected clock. The protocol is the version it records in jobs.lock.
func newJobsServer(dir, id string, protocol int, clock *fakeClock, job Job) *server {
	return &server{
		dir: dir, id: id, protocolVersion: protocol,
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
	a := newJobsServer(dir, "dev-a", ProtocolVersion, clock, jobA)
	b := newJobsServer(dir, "dev-b", ProtocolVersion, clock, jobB)

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

func TestOlderProtocolDoesNotTakeJobsFromANewerOwner(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	jobNewer, jobOlder, jobCurrent := newFakeJob(), newFakeJob(), newFakeJob()
	newer := newJobsServer(dir, "dev-newer", ProtocolVersion+1, clock, jobNewer)
	older := newJobsServer(dir, "dev-older", ProtocolVersion, clock, jobOlder)

	newer.tryJobsLock()
	waitForJobStart(t, jobNewer)
	stopJobsServer(newer)

	clock.Advance(jobsRetryInterval)
	older.tryJobsLock()
	if jobOlder.runs.Load() != 0 || older.jobsLock != nil {
		t.Fatal("older protocol took jobs from a newer owner")
	}

	current := newJobsServer(dir, "dev-current", ProtocolVersion+1, clock, jobCurrent)
	defer stopJobsServer(current)
	current.tryJobsLock()
	waitForJobStart(t, jobCurrent)
}

func TestNonCanonicalDaemonRunsJobsWhenTheLockIsFree(t *testing.T) {
	t.Parallel()
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	job := newFakeJob()
	// A go install binary gets a bin- identity; it must own jobs like any other daemon.
	s := newJobsServer(t.TempDir(), "bin-0123456789abcdef", ProtocolVersion, clock, job)
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
	owner := newJobsServer(dir, "dev-owner", ProtocolVersion, clock, job)
	owner.tryJobsLock()
	waitForJobStart(t, job)
	want(MonitoringActive)

	stopJobsServer(owner)
	want(MonitoringUnavailable)
}
