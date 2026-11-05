//go:build linux || darwin

package state

import (
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Delete must leave the manifest's lock file where it is. A caller blocked on
// the old file and a newcomer that creates a fresh one would both hold "the"
// lock.
func TestStoreDeleteKeepsTheManifestLockFile(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)
	const id = "qm-lock-kept"
	if err := s.Create(Manifest{SessionID: id, Cwd: "/tmp"}); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(s.lockPath(id))
	if err != nil {
		t.Fatalf("lock file after Create: %v", err)
	}

	if err := s.Delete(id); err != nil {
		t.Fatal(err)
	}

	after, err := os.Stat(s.lockPath(id))
	if err != nil {
		t.Fatalf("lock file after Delete: %v", err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("Delete replaced the lock file")
	}
}

// While one session ID is deleted and recreated over and over, its manifest
// lock never has two holders.
func TestStoreLockHasOneHolderWhileASessionIsDeletedAndRecreated(t *testing.T) {
	t.Parallel()
	s := newTestStore(t)
	const (
		id         = "qm-lock-contended"
		goroutines = 8
		iterations = 300
	)
	var holders, overlaps atomic.Int32
	hold := func() error {
		if holders.Add(1) > 1 {
			overlaps.Add(1)
		}
		time.Sleep(20 * time.Microsecond)
		holders.Add(-1)
		return nil
	}

	var wg sync.WaitGroup
	for g := range goroutines {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range iterations {
				switch (g + i) % 3 {
				case 0:
					_ = s.Create(Manifest{SessionID: id, Cwd: "/tmp"})
				case 1:
					_ = s.Delete(id)
				default:
					_ = s.withLock(id, hold)
				}
			}
		}()
	}
	wg.Wait()

	if n := overlaps.Load(); n > 0 {
		t.Fatalf("the manifest lock had two holders %d times", n)
	}
}
