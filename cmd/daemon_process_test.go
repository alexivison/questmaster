//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
)

type daemonHarness struct {
	t               *testing.T
	bin, home, root string
	env             []string
}

func newDaemonHarness(t *testing.T, root string) *daemonHarness {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "qm")
	build := exec.Command("go", "build", "-buildvcs=false", "-o", bin, "..")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	home := t.TempDir()
	if root == "" {
		root = t.TempDir()
	}
	link := filepath.Join(home, ".local", "bin", "questmaster")
	if err := os.MkdirAll(filepath.Dir(link), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(bin, link); err != nil {
		t.Fatal(err)
	}
	h := &daemonHarness{t: t, bin: bin, home: home, root: root, env: append(os.Environ(), "HOME="+home, "QUESTMASTER_STATE_ROOT="+root)}
	t.Cleanup(func() {
		_, _ = h.command("daemon", "stop")
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			status, err := h.command("daemon", "status")
			if err == nil && status["running"] == false {
				return
			}
			time.Sleep(20 * time.Millisecond)
		}
		status, err := h.command("daemon", "status")
		if err == nil {
			if pid, ok := status["pid"].(float64); ok && pid > 0 {
				_ = syscall.Kill(int(pid), syscall.SIGTERM)
			}
		}
		t.Errorf("daemon remained after cleanup: %v", status)
	})
	return h
}

func (h *daemonHarness) command(args ...string) (map[string]any, error) {
	return h.commandBin(h.bin, args...)
}

func (h *daemonHarness) commandBin(bin string, args ...string) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = h.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%v: %s", err, out)
	}
	var result map[string]any
	if err := json.Unmarshal(out, &result); err != nil {
		return nil, fmt.Errorf("%v: %s", err, out)
	}
	return result, nil
}

func (h *daemonHarness) must(args ...string) map[string]any {
	h.t.Helper()
	result, err := h.command(args...)
	if err != nil {
		h.t.Fatal(err)
	}
	return result
}

func (h *daemonHarness) waitStopped() {
	h.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		result, err := h.command("daemon", "status")
		if err == nil && result["running"] == false {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.t.Fatal("daemon did not stop")
}

func TestDaemonConcurrentStartAndStop(t *testing.T) {
	h := newDaemonHarness(t, "")
	var wg sync.WaitGroup
	errs := make(chan error, 12)
	for range 12 {
		wg.Add(1)
		go func() { defer wg.Done(); _, err := h.command("daemon", "start"); errs <- err }()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	first := h.must("daemon", "status")
	if first["identity"] != "canonical" || first["accepting"] != true {
		t.Fatalf("status: %+v", first)
	}
	worktreeCLI := filepath.Join(t.TempDir(), "qm-worktree")
	data, err := os.ReadFile(h.bin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(worktreeCLI, data, 0o700); err != nil {
		t.Fatal(err)
	}
	fromWorktree, err := h.commandBin(worktreeCLI, "daemon", "start")
	if err != nil {
		t.Fatal(err)
	}
	if fromWorktree["pid"] != first["pid"] {
		t.Fatalf("worktree CLI started a second daemon: %+v", fromWorktree)
	}
	second := h.must("daemon", "start")
	if second["pid"] != first["pid"] {
		t.Fatalf("duplicate daemon: %v, %v", first["pid"], second["pid"])
	}
	if loser := h.must("daemon", "run"); loser["running"] != false {
		t.Fatalf("second run did not exit: %+v", loser)
	}
	if stopped := h.must("daemon", "stop"); stopped["running"] != false {
		t.Fatalf("stop returned before exit: %+v", stopped)
	}
	h.waitStopped()
	time.Sleep(300 * time.Millisecond)
	if after := h.must("daemon", "status"); after["running"] != false {
		t.Fatalf("leftover run: %+v", after)
	}
}

func TestDaemonExitHandoff(t *testing.T) {
	for _, resume := range []bool{false, true} {
		t.Run(fmt.Sprint("resume=", resume), func(t *testing.T) {
			h := newDaemonHarness(t, "")
			helper := filepath.Join(t.TempDir(), "qm-exit-helper")
			build := exec.Command("go", "build", "-buildvcs=false", "-o", helper, "../internal/daemon/testdata/exithelper")
			if out, err := build.CombinedOutput(); err != nil {
				t.Fatalf("helper build: %v\n%s", err, out)
			}
			link := filepath.Join(h.home, ".local", "bin", "questmaster")
			if err := os.Remove(link); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(helper, link); err != nil {
				t.Fatal(err)
			}
			old := h.must("daemon", "start")
			release := filepath.Join(h.root, "daemon", "release-drain")
			t.Cleanup(func() { _ = os.WriteFile(release, nil, 0o600) })
			deadline := time.Now().Add(5 * time.Second)
			for {
				if _, err := os.Stat(filepath.Join(h.root, "daemon", "draining")); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("idle listener did not close")
				}
				time.Sleep(10 * time.Millisecond)
			}
			if resume {
				if err := os.WriteFile(filepath.Join(h.root, "daemon", "work"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			results := make(chan struct {
				result map[string]any
				err    error
			}, 8)
			for range 8 {
				go func() {
					result, err := h.command("daemon", "start")
					results <- struct {
						result map[string]any
						err    error
					}{result, err}
				}()
			}
			if err := os.WriteFile(release, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			var pid float64
			for range 8 {
				call := <-results
				if call.err != nil {
					t.Fatal(call.err)
				}
				result := call.result
				if pid == 0 {
					pid = result["pid"].(float64)
				}
				if result["pid"] != pid {
					t.Fatalf("two daemons after handoff: %v, %v", pid, result["pid"])
				}
			}
			if resume && pid != old["pid"] {
				t.Fatalf("old daemon did not resume: %v, %v", old["pid"], pid)
			}
			if !resume && pid == old["pid"] {
				t.Fatalf("old daemon did not exit: %v", pid)
			}
			if !resume {
				if err := os.WriteFile(filepath.Join(h.root, "daemon", "work"), nil, 0o600); err != nil {
					t.Fatal(err)
				}
			}
			if status := h.must("daemon", "status"); status["pid"] != pid {
				t.Fatalf("handoff status: %+v", status)
			}
			time.Sleep(150 * time.Millisecond)
			ps := exec.Command("ps", "-eo", "pid=,command=")
			out, err := ps.Output()
			if err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, line := range strings.Split(string(out), "\n") {
				if strings.Contains(line, helper+" daemon run") {
					count++
				}
			}
			if count != 1 {
				t.Fatalf("helper run process count = %d", count)
			}
			h.must("daemon", "stop")
			h.waitStopped()
		})
	}
}

func TestDaemonStaleSocketAndLongRoot(t *testing.T) {
	for _, long := range []bool{false, true} {
		t.Run(fmt.Sprint("long=", long), func(t *testing.T) {
			root := t.TempDir()
			if long {
				root = filepath.Join(root, strings.Repeat("r", 100))
			}
			h := newDaemonHarness(t, root)
			if !long {
				path, err := daemon.SocketPath(root, "canonical")
				if err != nil {
					t.Fatal(err)
				}
				if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
					t.Fatal(err)
				}
				ln, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
				if err != nil {
					t.Fatal(err)
				}
				ln.SetUnlinkOnClose(false)
				if err := ln.Close(); err != nil {
					t.Fatal(err)
				}
			}
			status := h.must("daemon", "start")
			socket := status["socket"].(string)
			if long && (!strings.HasPrefix(socket, "/tmp/qm-") || len(socket) >= 104) {
				t.Fatalf("fallback: %q", socket)
			}
			info, err := os.Lstat(socket)
			if err != nil {
				t.Fatal(err)
			}
			if info.Mode().Perm() != 0o600 {
				t.Fatalf("socket mode = %o", info.Mode().Perm())
			}
			h.must("daemon", "stop")
			h.waitStopped()
		})
	}
}

func TestDaemonStatusReportsMismatchedHandshake(t *testing.T) {
	h := newDaemonHarness(t, "")
	socket, err := daemon.SocketPath(h.root, "canonical")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(h.root, "daemon"), 0o700); err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = json.NewEncoder(conn).Encode(map[string]any{"root": "wrong", "identity": "canonical", "protocol_version": daemon.ProtocolVersion, "accepting": true})
	}()
	if _, err := h.command("daemon", "status"); err == nil {
		t.Fatal("status hid a mismatched handshake")
	}
}

func TestDaemonCanonicalAndDevJobs(t *testing.T) {
	h := newDaemonHarness(t, "")
	canonical := h.must("daemon", "start")
	if err := os.WriteFile(filepath.Join(h.root, "daemon", "test-work"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if status := h.must("daemon", "status"); status["has_work"] != false {
		t.Fatalf("production daemon ran a test job: %+v", status)
	}
	dev := filepath.Join(h.root, "daemon", "bin", "dev-test", "exe", "qm")
	if err := os.MkdirAll(filepath.Dir(dev), 0o700); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(h.bin)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dev, data, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _, _ = h.commandBin(dev, "daemon", "stop") })
	devRun := exec.Command(dev, "daemon", "run", "--jobs")
	devRun.Env = h.env
	if err := devRun.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = devRun.Process.Signal(syscall.SIGTERM); _ = devRun.Wait() })
	var child map[string]any
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		child, err = h.commandBin(dev, "daemon", "status")
		if err == nil && child["running"] == true {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil || child["running"] != true {
		t.Fatalf("dev did not start: %v", err)
	}
	if canonical["jobs"] != true || child["jobs"] != false || child["identity"] != "dev-test" {
		t.Fatalf("canonical=%+v dev=%+v", canonical, child)
	}
	if child["has_work"] != false {
		t.Fatalf("dev daemon reported another daemon's work: %+v", child)
	}
	if canonical["pid"] == child["pid"] {
		t.Fatal("dev and canonical share a process")
	}
	lock, err := os.OpenFile(filepath.Join(h.root, "daemon", "jobs.lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
		t.Fatalf("jobs.lock not held exclusively: %v", err)
	}
	if _, err := h.commandBin(dev, "daemon", "stop"); err != nil {
		t.Fatal(err)
	}
	h.must("daemon", "stop")
	h.waitStopped()
}

func TestDaemonUpgradeProbeRejectsUnreadyBinary(t *testing.T) {
	h := newDaemonHarness(t, "")
	if result := h.must("daemon", "check-upgrade"); result["running"] != false {
		t.Fatalf("check-upgrade started a daemon: %+v", result)
	}
	if result := h.must("daemon", "status"); result["running"] != false {
		t.Fatalf("check-upgrade started a daemon: %+v", result)
	}
	version := h.must("version", "--json")
	if version["protocol_version"] != float64(daemon.ProtocolVersion) {
		t.Fatalf("version: %+v", version)
	}
	status := h.must("daemon", "start")
	socket := status["socket"].(string)
	check := func() bool {
		t.Helper()
		conn, err := net.DialTimeout("unix", socket, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		dec := json.NewDecoder(conn)
		var handshake map[string]any
		if err := dec.Decode(&handshake); err != nil {
			t.Fatal(err)
		}
		if err := json.NewEncoder(conn).Encode(map[string]any{"method": "check-upgrade", "protocol_version": 999}); err != nil {
			t.Fatal(err)
		}
		var response struct {
			OK   bool `json:"ok"`
			Data struct {
				UpgradeAvailable bool `json:"upgrade_available"`
			} `json:"data"`
		}
		if err := dec.Decode(&response); err != nil {
			t.Fatal(err)
		}
		if !response.OK {
			t.Fatal("version-independent check-upgrade rejected")
		}
		return response.Data.UpgradeAvailable
	}
	backup := h.bin + ".old"
	if err := os.Rename(h.bin, backup); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := os.Stat(h.bin); os.IsNotExist(err) {
			_ = os.Rename(backup, h.bin)
		}
	})
	if check() {
		t.Fatal("missing binary accepted")
	}
	if err := os.WriteFile(h.bin, []byte("partial"), 0o700); err != nil {
		t.Fatal(err)
	}
	if check() {
		t.Fatal("partial binary accepted")
	}
	data, err := os.ReadFile(backup)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.bin, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if check() {
		t.Fatal("non-runnable binary accepted")
	}
	childPIDFile := filepath.Join(h.root, "probe-child.pid")
	script := fmt.Sprintf("#!/bin/sh\nsleep 30 &\nprintf '%%s' \"$!\" > %q\nwait\n", childPIDFile)
	if err := os.WriteFile(h.bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(h.bin, 0o700); err != nil {
		t.Fatal(err)
	}
	if check() {
		t.Fatal("hung probe accepted")
	}
	pidText, err := os.ReadFile(childPIDFile)
	if err != nil {
		t.Fatal(err)
	}
	childPID, err := strconv.Atoi(string(pidText))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && syscall.Kill(childPID, 0) == nil {
		time.Sleep(20 * time.Millisecond)
	}
	if syscall.Kill(childPID, 0) == nil {
		_ = syscall.Kill(childPID, syscall.SIGKILL)
		t.Fatal("probe child survived its timeout")
	}
	candidate := h.bin + ".new"
	build := exec.Command("go", "build", "-buildvcs=false", "-ldflags=-buildid=d1-upgrade-probe", "-o", candidate, "..")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("candidate build: %v\n%s", err, out)
	}
	if err := os.Rename(candidate, h.bin); err != nil {
		t.Fatal(err)
	}
	if !check() {
		t.Fatal("valid replacement was not recognized")
	}
	if err := os.Rename(h.bin, h.bin+".valid"); err != nil {
		t.Fatal(err)
	}
	if check() {
		t.Fatal("upgrade availability stayed true after binary disappeared")
	}
	if err := os.Rename(h.bin+".valid", h.bin); err != nil {
		t.Fatal(err)
	}
	if after := h.must("daemon", "status"); after["generation"] != float64(1) {
		t.Fatalf("D1 unexpectedly re-execed: %+v", after)
	}
}

func TestDaemonLogRotationKeepsStderrCurrent(t *testing.T) {
	h := newDaemonHarness(t, "")
	dir := filepath.Join(h.root, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(dir, "canonical.log")
	if err := os.WriteFile(log, bytes.Repeat([]byte("x"), 5*1024*1024), 0o600); err != nil {
		t.Fatal(err)
	}
	h.must("daemon", "start")
	h.must("daemon", "stop")
	h.waitStopped()
	current, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(current, []byte("daemon stopping")) {
		t.Fatalf("stderr did not reach current log: %q", current)
	}
	old, err := os.Stat(log + ".1")
	if err != nil {
		t.Fatal(err)
	}
	if old.Size() != 5*1024*1024 {
		t.Fatalf("rotated size = %d", old.Size())
	}
}

func TestDaemonIdleExitAndSIGTERM(t *testing.T) {
	h := newDaemonHarness(t, "")
	startRun := func(grace string) *exec.Cmd {
		cmd := exec.Command(h.bin, "daemon", "run", "--idle-grace="+grace)
		cmd.Env = h.env
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			status, err := h.command("daemon", "status")
			if err == nil && status["running"] == true {
				return cmd
			}
			time.Sleep(20 * time.Millisecond)
		}
		t.Fatal("run did not become ready")
		return nil
	}
	idle := startRun("300ms")
	if err := idle.Wait(); err != nil {
		t.Fatal(err)
	}
	h.waitStopped()
	signaled := startRun("10m")
	if err := signaled.Process.Signal(syscall.SIGTERM); err != nil {
		t.Fatal(err)
	}
	if err := signaled.Wait(); err != nil {
		t.Fatal(err)
	}
	h.waitStopped()
}
