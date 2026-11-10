//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
)

// pauseRunner lets goroutines share a mockRunner, which is not safe for
// concurrent use, and holds the first call that matches until release closes.
// The held call waits outside the lock, so other callers keep running.
type pauseRunner struct {
	mu      sync.Mutex
	runner  tmux.Runner
	match   func(args []string) bool
	once    sync.Once
	paused  chan struct{}
	release chan struct{}
}

func newPauseRunner(runner tmux.Runner, match func(args []string) bool) *pauseRunner {
	return &pauseRunner{runner: runner, match: match, paused: make(chan struct{}), release: make(chan struct{})}
}

func (r *pauseRunner) Run(ctx context.Context, args ...string) (string, error) {
	if r.match(args) {
		r.once.Do(func() {
			close(r.paused)
			<-r.release
		})
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.runner.Run(ctx, args...)
}

type startOutcome struct {
	result StartResult
	err    error
}

// waitBriefly returns the value on ch if it arrives within a short window. The
// window lets an unserialized operation run to completion; a serialized one
// stays blocked behind the paused call.
func waitBriefly[T any](ch <-chan T) (T, bool) {
	select {
	case v := <-ch:
		return v, true
	case <-time.After(200 * time.Millisecond):
		var zero T
		return zero, false
	}
}

const (
	lockTestMasterID = "qm-orphan-master"
	lockTestWorkerID = "qm-4100"
)

func setupMasterForLockTest(t *testing.T, match func(args []string) bool) (*Service, *mockRunner, *pauseRunner) {
	t.Helper()
	setTestStateRoot(t, t.TempDir())
	svc, runner := setupService(t)
	pause := newPauseRunner(runner, match)
	svc.Client = tmux.NewClient(pause)
	svc.Now = func() int64 { return 4100 }
	createTestManifest(t, svc.Store, lockTestMasterID, "master", t.TempDir(), "master")
	runner.sessions[lockTestMasterID] = true
	return svc, runner, pause
}

func startWorker(svc *Service, ctx context.Context) <-chan startOutcome {
	started := make(chan startOutcome, 1)
	go func() {
		result, err := svc.Start(ctx, StartOpts{Cwd: "/tmp", MasterID: lockTestMasterID, Title: "late worker"})
		started <- startOutcome{result, err}
	}()
	return started
}

func deleteMaster(svc *Service, ctx context.Context) <-chan error {
	deleted := make(chan error, 1)
	go func() {
		_, err := svc.Delete(ctx, lockTestMasterID)
		deleted <- err
	}()
	return deleted
}

// assertNoOrphanWorker checks the end state: the master is gone, and so is
// every trace of the worker.
func assertNoOrphanWorker(t *testing.T, svc *Service, runner *mockRunner, start startOutcome) {
	t.Helper()
	if _, err := svc.Store.Read(lockTestMasterID); err == nil {
		t.Fatal("master manifest survived Delete")
	}
	if runner.sessions[lockTestWorkerID] {
		t.Fatalf("worker %s is alive after its master was deleted (Start: %v)", lockTestWorkerID, start.err)
	}
	if _, err := svc.Store.Read(lockTestWorkerID); err == nil {
		t.Fatalf("worker manifest survived its master's Delete (Start: %v)", start.err)
	}
}

// Start pauses after registering the worker, before creating its tmux
// session, while the master is deleted.
func TestStartPausedAfterRegisteringWhileItsMasterIsDeleted(t *testing.T) {
	svc, runner, pause := setupMasterForLockTest(t, func(args []string) bool {
		return args[0] == "new-session" && flagVal(args, "-s") == lockTestWorkerID
	})
	ctx := t.Context()

	started := startWorker(svc, ctx)
	<-pause.paused
	deleted := deleteMaster(svc, ctx)
	deleteErr, deleteDone := waitBriefly(deleted)
	close(pause.release)
	start := <-started
	if !deleteDone {
		deleteErr = <-deleted
	}

	if deleteErr != nil {
		t.Fatalf("Delete: %v", deleteErr)
	}
	assertNoOrphanWorker(t, svc, runner, start)
}

// The master's Delete pauses after reading its worker list, which does not
// have the new worker yet, while Start registers and launches the worker.
func TestStartWhileItsMasterIsDeletedAfterReadingItsWorkers(t *testing.T) {
	svc, runner, pause := setupMasterForLockTest(t, func(args []string) bool {
		return args[0] == "kill-session" && flagVal(args, "-t") == tmux.SessionTarget(lockTestMasterID)
	})
	ctx := t.Context()

	deleted := deleteMaster(svc, ctx)
	<-pause.paused
	started := startWorker(svc, ctx)
	start, startDone := waitBriefly(started)
	close(pause.release)
	if err := <-deleted; err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if !startDone {
		start = <-started
	}

	assertNoOrphanWorker(t, svc, runner, start)
}

// hangUntilDeadline makes the tmux commands named cmd block until their context
// ends, as a tmux server that stops answering would, while hanging is set. Like
// exec.CommandContext, it runs nothing on a context that has already ended.
func hangUntilDeadline(runner *mockRunner, cmd string, hanging *atomic.Bool) {
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if hanging.Load() && len(args) > 0 && args[0] == cmd {
			<-ctx.Done()
			return "", ctx.Err()
		}
		return runner.defaultHandler(ctx, args...)
	}
}

type controlledDeadline struct {
	context.Context
	done chan struct{}
	once sync.Once
}

func (d *controlledDeadline) Done() <-chan struct{} { return d.done }

func (d *controlledDeadline) Err() error {
	select {
	case <-d.done:
		return context.DeadlineExceeded
	default:
		return nil
	}
}

func (d *controlledDeadline) expire() { d.once.Do(func() { close(d.done) }) }

// A tmux server that stops answering holds a session's lifecycle lock only
// until the lifecycle deadline.
func TestLifecycleDeadlineReleasesTheLockWhenTmuxHangs(t *testing.T) {
	setTestStateRoot(t, t.TempDir())
	svc, runner := setupService(t)
	svc.lifecycleTimeout = 100 * time.Millisecond
	const id = "qm-hung"
	createTestManifest(t, svc.Store, id, "hung", t.TempDir(), "")
	var hanging atomic.Bool
	hanging.Store(true)
	hangUntilDeadline(runner, "kill-session", &hanging)

	began := time.Now()
	_, err := svc.Delete(t.Context(), id)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Delete error = %v, want the lifecycle deadline", err)
	}
	if elapsed := time.Since(began); elapsed > 2*time.Second {
		t.Fatalf("Delete took %s against a hung tmux, want about the 100ms deadline", elapsed)
	}

	hanging.Store(false)
	if _, err := svc.Delete(t.Context(), id); err != nil {
		t.Fatalf("Delete after the deadline: %v (lock still held?)", err)
	}
}

// A launch step that runs into the deadline still rolls back: the kill gets a
// context of its own.
func TestContinueRollbackRunsAfterTheDeadline(t *testing.T) {
	setTestStateRoot(t, t.TempDir())
	svc, runner := setupService(t)
	svc.lifecycleTimeout = 30 * time.Second
	const id = "qm-late-rollback"
	createTestManifest(t, svc.Store, id, "late", t.TempDir(), "")
	deadline := &controlledDeadline{Context: t.Context(), done: make(chan struct{})}
	defer deadline.expire()
	reachedLaunch := make(chan struct{}, 1)
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		if len(args) > 0 && args[0] == "set-environment" {
			reachedLaunch <- struct{}{}
			<-ctx.Done()
			return "", ctx.Err()
		}
		return runner.defaultHandler(ctx, args...)
	}
	continued := make(chan error, 1)
	go func() {
		_, err := svc.Continue(deadline, id)
		continued <- err
	}()
	<-reachedLaunch
	deadline.expire()

	if err := <-continued; !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Continue error = %v, want the lifecycle deadline", err)
	}

	if !runner.hasCall("kill-session", "-t", tmux.SessionTarget(id)) {
		t.Fatalf("no rollback kill after the deadline: %v", runner.calls)
	}
	if runner.sessions[id] {
		t.Fatal("the session this Continue created survived its failed launch")
	}
}
