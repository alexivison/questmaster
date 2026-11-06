//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/daemon"
	"github.com/alexivison/questmaster/internal/state"
)

func TestDaemonPRJobKeepsProcessAliveUntilWatcherDies(t *testing.T) {
	h := newDaemonHarness(t, "")
	store := state.OpenStore(h.root)
	if err := store.Create(state.Manifest{SessionID: "qm-pr-job"}); err != nil {
		t.Fatal(err)
	}
	ref, err := state.ParsePullRequestRef("owner/repo#1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(h.root, "qm-pr-job", ref, time.Now()); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(h.root, "live")
	if err := os.WriteFile(marker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	binDir := filepath.Join(h.root, "daemon", "bin", "canonical")
	if err := os.MkdirAll(binDir, 0700); err != nil {
		t.Fatal(err)
	}
	for name, script := range map[string]string{
		"tmux": fmt.Sprintf("#!/bin/sh\nif [ -f %q ]; then printf 'qm-pr-job\\n'; fi\n", marker),
		"gh":   "#!/bin/sh\nprintf '%s\\n' '{\"data\":{\"p0\":{\"pullRequest\":{\"title\":\"PR\",\"state\":\"OPEN\"}}}}'\n",
	} {
		if err := os.WriteFile(filepath.Join(binDir, name), []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	cmd := exec.Command(h.bin, "daemon", "run", "--jobs", "--idle-grace=300ms")
	cmd.Env = h.env
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	done := make(chan struct{})
	go func() { exited <- cmd.Wait(); close(done) }()
	t.Cleanup(func() {
		_ = cmd.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(3 * time.Second):
		}
	})
	deadline := time.Now().Add(30 * time.Second)
	var status map[string]any
	var statusErr error
	for time.Now().Before(deadline) {
		status, statusErr = h.command("daemon", "status")
		if statusErr == nil && status["running"] == true && status["has_work"] == true {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if statusErr != nil || status["running"] != true || status["has_work"] != true {
		t.Fatalf("job not active: %v %v\n%s", status, statusErr, output.String())
	}
	statusPath := state.PullRequestStatusPath(h.root)
	deadline = time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(statusPath); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(statusPath); err != nil {
		t.Fatalf("job did not fetch: %v\n%s", err, output.String())
	}
	refreshed, err := h.command("pr", "--session", "qm-pr-job", "refresh", "owner/repo#1")
	if err != nil {
		t.Fatalf("CLI refresh through daemon: %v\n%s", err, output.String())
	}
	prs, ok := refreshed["pull_requests"].([]any)
	if !ok || len(prs) != 1 || prs[0].(map[string]any)["status"].(map[string]any)["title"] != "PR" {
		t.Fatalf("CLI refresh result: %v", refreshed)
	}
	time.Sleep(400 * time.Millisecond)
	if status := h.must("daemon", "status"); status["running"] != true {
		t.Fatalf("job idled with live watcher: %v", status)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-exited:
		if err != nil {
			t.Fatalf("daemon exit: %v\n%s", err, output.String())
		}
	case <-time.After(30 * time.Second):
		t.Fatalf("daemon did not idle out\n%s", output.String())
	}
}

type daemonHarness struct {
	t               *testing.T
	bin, home, root string
	env             []string
}

type cachedDaemonBuild struct {
	sync.Once
	path   string
	output []byte
	err    error
}

var cachedDaemonCLI, cachedDaemonHelper, cachedDaemonReplacement, cachedDaemonHelperReplacement cachedDaemonBuild

func (b *cachedDaemonBuild) binary(t *testing.T, source string, flags ...string) string {
	t.Helper()
	b.Do(func() {
		var dir string
		dir, b.err = os.MkdirTemp("", "qm-daemon-test-build-*")
		if b.err != nil {
			return
		}
		b.path = filepath.Join(dir, "qm")
		args := append([]string{"build", "-p=1", "-buildvcs=false"}, flags...)
		args = append(args, "-o", b.path, source)
		build := exec.CommandContext(t.Context(), "go", args...)
		build.Env = append(os.Environ(), "GOPROXY=off")
		b.output, b.err = build.CombinedOutput()
	})
	if b.err != nil {
		t.Fatalf("build %s: %v\n%s", source, b.err, b.output)
	}
	return b.path
}

func copyDaemonBinary(t *testing.T, source, dest string) {
	t.Helper()
	data, err := os.ReadFile(source)
	if err != nil {
		t.Fatal(err)
	}
	syscall.ForkLock.Lock()
	defer syscall.ForkLock.Unlock()
	tmp, err := os.CreateTemp(filepath.Dir(dest), "qm-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		t.Fatal(err)
	}
	if err := tmp.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tmp.Name(), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp.Name(), dest); err != nil {
		t.Fatal(err)
	}
}

func newDaemonHarness(t *testing.T, root string) *daemonHarness {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "qm")
	copyDaemonBinary(t, cachedDaemonCLI.binary(t, ".."), bin)
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

func (h *daemonHarness) waitGeneration(generation float64) map[string]any {
	h.t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	var last map[string]any
	var lastErr error
	for time.Now().Before(deadline) {
		last, lastErr = h.command("daemon", "status")
		if lastErr == nil && last["generation"] == generation {
			return last
		}
		time.Sleep(20 * time.Millisecond)
	}
	h.t.Fatalf("timed out waiting for daemon generation %.0f: last status=%+v, error=%v", generation, last, lastErr)
	return nil
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
			copyDaemonBinary(t, cachedDaemonHelper.binary(t, "../internal/daemon/testdata/exithelper"), helper)
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
	check := func() (bool, error) {
		t.Helper()
		conn, err := net.DialTimeout("unix", socket, 5*time.Second)
		if err != nil {
			return false, fmt.Errorf("dial upgrade socket: %w", err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
		dec := json.NewDecoder(conn)
		var handshake map[string]any
		if err := dec.Decode(&handshake); err != nil {
			return false, fmt.Errorf("read upgrade handshake: %w", err)
		}
		if err := json.NewEncoder(conn).Encode(map[string]any{"method": "check-upgrade", "protocol_version": 999}); err != nil {
			return false, fmt.Errorf("send upgrade probe: %w", err)
		}
		var response struct {
			OK   bool `json:"ok"`
			Data struct {
				UpgradeAvailable bool `json:"upgrade_available"`
			} `json:"data"`
		}
		if err := dec.Decode(&response); err != nil {
			return false, fmt.Errorf("read upgrade probe: %w", err)
		}
		if !response.OK {
			return false, errors.New("version-independent check-upgrade rejected")
		}
		return response.Data.UpgradeAvailable, nil
	}
	mustCheck := func() bool {
		t.Helper()
		available, err := check()
		if err != nil {
			t.Fatal(err)
		}
		return available
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
	if mustCheck() {
		t.Fatal("missing binary accepted")
	}
	if err := os.WriteFile(h.bin, []byte("partial"), 0o700); err != nil {
		t.Fatal(err)
	}
	if mustCheck() {
		t.Fatal("partial binary accepted")
	}
	data, err := os.ReadFile(backup)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(h.bin, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if mustCheck() {
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
	if mustCheck() {
		t.Fatal("hung probe accepted")
	}
	deadline := time.Now().Add(15 * time.Second)
	var pidText []byte
	for time.Now().Before(deadline) {
		pidText, err = os.ReadFile(childPIDFile)
		if err == nil && len(pidText) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(pidText) == 0 {
		t.Fatalf("timed out waiting for hung probe child PID file: %v", err)
	}
	childPID, err := strconv.Atoi(string(pidText))
	if err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) && syscall.Kill(childPID, 0) == nil {
		time.Sleep(20 * time.Millisecond)
	}
	if syscall.Kill(childPID, 0) == nil {
		_ = syscall.Kill(childPID, syscall.SIGKILL)
		t.Fatal("timed out waiting for probe child to exit after its timeout")
	}
	candidate := h.bin + ".new"
	copyDaemonBinary(t, cachedDaemonReplacement.binary(t, "..", "-ldflags=-buildid=daemon-test-replacement"), candidate)
	if err := os.Rename(candidate, h.bin); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(45 * time.Second)
	var lastErr error
	recognized := false
	for time.Now().Before(deadline) {
		available, err := check()
		if err == nil && available {
			recognized = true
			break
		}
		lastErr = err
		time.Sleep(20 * time.Millisecond)
	}
	if !recognized {
		t.Fatalf("timed out waiting for valid replacement to be recognized: last probe error=%v", lastErr)
	}
	h.waitGeneration(2)
	if err := os.Rename(h.bin, h.bin+".valid"); err != nil {
		t.Fatal(err)
	}
	if mustCheck() {
		t.Fatal("upgrade availability stayed true after binary disappeared")
	}
	if err := os.Rename(h.bin+".valid", h.bin); err != nil {
		t.Fatal(err)
	}
	if after := h.must("daemon", "status"); after["generation"] != float64(2) {
		t.Fatalf("replacement generation changed: %+v", after)
	}
}

func TestDaemonDevBuildFromStablePath(t *testing.T) {
	h := newDaemonHarness(t, "")
	goDir := t.TempDir()
	// The CLI still builds twice; the test supplies the already-built fixture so
	// compiler scheduling cannot consume the daemon's readiness deadline.
	goBuild := `#!/bin/sh
if [ "$#" -ne 5 ] || [ "$1" != build ] || [ "$2" != -buildvcs=false ] || [ "$3" != -o ] || [ "$5" != . ] || [ "$(pwd -P)" != "$QUESTMASTER_TEST_WORKTREE" ]; then
	printf 'unexpected go build arguments\n' >&2
	exit 2
fi
cp "$QUESTMASTER_TEST_BINARY" "$4"
`
	if err := os.WriteFile(filepath.Join(goDir, "go"), []byte(goBuild), 0o700); err != nil {
		t.Fatal(err)
	}
	worktree, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	resolvedWorktree, err := filepath.EvalSymlinks(worktree)
	if err != nil {
		t.Fatal(err)
	}
	h.env = append(h.env, "PATH="+goDir+":"+os.Getenv("PATH"), "QUESTMASTER_TEST_BINARY="+cachedDaemonCLI.binary(t, ".."), "QUESTMASTER_TEST_WORKTREE="+resolvedWorktree, "GOPROXY=off")
	start := func() map[string]any {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, h.bin, "daemon", "start", "--build-from", worktree)
		cmd.Env = h.env
		var out, stderr bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &stderr
		if err := cmd.Run(); err != nil {
			if ctx.Err() != nil {
				t.Fatalf("timed out waiting for dev daemon ready handshake: %v\n%s", ctx.Err(), stderr.String())
			}
			t.Fatalf("dev start: %v\n%s", err, stderr.String())
		}
		var record map[string]any
		if err := json.Unmarshal(out.Bytes(), &record); err != nil {
			t.Fatalf("dev start JSON: %v; stdout=%s; stderr=%s", err, out.String(), stderr.String())
		}
		return record
	}
	t.Cleanup(func() {
		_, _ = h.command("daemon", "stop", "--build-from", worktree)
	})
	first := start()
	second := start()
	if first["identity"] != second["identity"] || first["pid"] != second["pid"] {
		t.Fatalf("dev start was not idempotent: %v %v", first, second)
	}
	if first["jobs"] != false {
		t.Fatalf("dev daemon took jobs without --jobs: %v", first)
	}
	if _, err := os.Lstat(filepath.Join(h.root, "bin", "current", "qm")); !os.IsNotExist(err) {
		t.Fatalf("development daemon created the stable link: %v", err)
	}
	dev := first["executable"].(string)
	if !strings.Contains(dev, "/daemon/bin/dev-") || !strings.HasSuffix(dev, "/exe/qm") {
		t.Fatalf("unstable dev executable: %s", dev)
	}
	if _, err := os.Stat(dev); err != nil {
		t.Fatal(err)
	}
	if _, err := h.commandBin(dev, "daemon", "stop"); err != nil {
		t.Fatal(err)
	}
}

func TestDaemonReexecKeepsPIDSocketAndJobsLock(t *testing.T) {
	h := newDaemonHarness(t, "")
	before := h.must("daemon", "start")
	socket := before["socket"].(string)
	held, err := net.DialTimeout("unix", socket, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	oldDecoder := json.NewDecoder(held)
	var oldHello struct {
		Generation int `json:"generation"`
	}
	if err := oldDecoder.Decode(&oldHello); err != nil || oldHello.Generation != 1 {
		t.Fatalf("initial handshake: %+v %v", oldHello, err)
	}
	subConn, err := net.DialTimeout("unix", socket, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer subConn.Close()
	subDecoder := json.NewDecoder(subConn)
	var subLine map[string]any
	for _, step := range []string{"handshake", "subscribe response", "initial event"} {
		if step == "subscribe response" {
			if err := json.NewEncoder(subConn).Encode(map[string]any{"method": "subscribe"}); err != nil {
				t.Fatal(err)
			}
		}
		if err := subDecoder.Decode(&subLine); err != nil {
			t.Fatalf("%s: %v", step, err)
		}
	}
	if subLine["type"] != "event" || subLine["topic"] != "tracker" {
		t.Fatalf("initial subscription event: %+v", subLine)
	}
	shim := filepath.Join(h.root, "daemon", "bin", "canonical", "qm")
	oldShim, err := os.Stat(shim)
	if err != nil {
		t.Fatal(err)
	}
	candidate := h.bin + ".new"
	copyDaemonBinary(t, cachedDaemonReplacement.binary(t, "..", "-ldflags=-buildid=daemon-test-replacement"), candidate)
	if err := os.Rename(candidate, h.bin); err != nil {
		t.Fatal(err)
	}
	stopDial, firstDial := make(chan struct{}), make(chan struct{})
	dialError := make(chan error, 1)
	var dialDone sync.WaitGroup
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			close(stopDial)
			dialDone.Wait()
		})
	}
	defer stop()
	dialDone.Add(1)
	go func() {
		defer dialDone.Done()
		first := true
		for {
			select {
			case <-stopDial:
				return
			default:
			}
			conn, err := net.DialTimeout("unix", socket, 100*time.Millisecond)
			if err != nil {
				var netErr net.Error
				if errors.As(err, &netErr) && netErr.Timeout() {
					continue
				}
				dialError <- err
				return
			}
			conn.Close()
			if first {
				close(firstDial)
				first = false
			}
			time.Sleep(2 * time.Millisecond)
		}
	}()
	select {
	case <-firstDial:
	case err := <-dialError:
		t.Fatalf("socket dial failed before re-exec: %v", err)
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for an initial socket connection before re-exec")
	}
	check := h.must("daemon", "check-upgrade")
	if check["upgrade_started"] != true {
		t.Fatalf("upgrade was not started: %+v", check)
	}
	after := h.waitGeneration(2)
	stop()
	select {
	case err := <-dialError:
		log, _ := os.ReadFile(filepath.Join(h.root, "daemon", "canonical.log"))
		t.Fatalf("socket dial failed during re-exec: %v; after=%+v; log=%s", err, after, log)
	default:
	}
	if after["generation"] != float64(2) || after["pid"] != before["pid"] || after["socket"] != socket {
		t.Fatalf("re-exec changed daemon identity: before=%+v after=%+v", before, after)
	}
	_ = held.SetReadDeadline(time.Now().Add(10 * time.Second))
	var staleReply map[string]any
	if err := oldDecoder.Decode(&staleReply); !errors.Is(err, io.EOF) {
		t.Fatalf("old connection did not close on re-exec: %v %+v", err, staleReply)
	}
	_ = subConn.SetReadDeadline(time.Now().Add(10 * time.Second))
	for {
		subLine = nil
		err := subDecoder.Decode(&subLine)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatalf("old subscription did not close on re-exec: %v %+v", err, subLine)
		}
	}
	fresh, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	var freshHello struct {
		Generation int `json:"generation"`
	}
	if err := json.NewDecoder(fresh).Decode(&freshHello); err != nil || freshHello.Generation != 2 {
		fresh.Close()
		t.Fatalf("replacement handshake: %+v %v", freshHello, err)
	}
	fresh.Close()
	freshSub, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer freshSub.Close()
	freshSubDecoder := json.NewDecoder(freshSub)
	var freshLine map[string]any
	if err := freshSubDecoder.Decode(&freshLine); err != nil || freshLine["generation"] != float64(2) {
		t.Fatalf("replacement subscription handshake: %+v %v", freshLine, err)
	}
	if err := json.NewEncoder(freshSub).Encode(map[string]any{"method": "subscribe"}); err != nil {
		t.Fatal(err)
	}
	if err := freshSubDecoder.Decode(&freshLine); err != nil || freshLine["type"] != "response" {
		t.Fatalf("replacement subscribe response: %+v %v", freshLine, err)
	}
	if err := freshSubDecoder.Decode(&freshLine); err != nil || freshLine["type"] != "event" || freshLine["topic"] != "tracker" {
		t.Fatalf("replacement initial event: %+v %v", freshLine, err)
	}
	newShim, err := os.Stat(shim)
	if err != nil || os.SameFile(oldShim, newShim) {
		t.Fatalf("shim was not rewritten on re-exec: %v", err)
	}
	if after["jobs"] != true {
		t.Fatalf("jobs were not restarted: %+v", after)
	}
	lock, err := os.OpenFile(filepath.Join(h.root, "daemon", "jobs.lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
		t.Fatalf("jobs.lock was lost during re-exec: %v", err)
	}
	if status := h.must("daemon", "status"); status["generation"] != float64(2) {
		t.Fatalf("request after swap failed: %+v", status)
	}
	h.must("daemon", "stop")
	h.waitStopped()
}

func daemonRequest(socket, method string) error {
	conn, err := net.DialTimeout("unix", socket, time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	dec := json.NewDecoder(conn)
	var greeting map[string]any
	if err := dec.Decode(&greeting); err != nil {
		return err
	}
	if err := json.NewEncoder(conn).Encode(map[string]any{"method": "start", "data": map[string]any{"title": method}, "protocol_version": daemon.ProtocolVersion}); err != nil {
		return err
	}
	var reply struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := dec.Decode(&reply); err != nil {
		return err
	}
	if !reply.OK {
		return fmt.Errorf("%s: %s", method, reply.Error)
	}
	return nil
}

func TestDaemonReexecWaitsForWorkAndDoesNotLeakLocksToChild(t *testing.T) {
	h := newDaemonHarness(t, "")
	helper := filepath.Join(t.TempDir(), "qm-helper")
	copyDaemonBinary(t, cachedDaemonHelper.binary(t, "../internal/daemon/testdata/exithelper"), helper)
	link := filepath.Join(h.home, ".local", "bin", "questmaster")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(helper, link); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"work", "release-drain"} {
		if err := os.MkdirAll(filepath.Join(h.root, "daemon"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(h.root, "daemon", name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	run := exec.Command(helper, "daemon", "run")
	run.Env = h.env
	if err := run.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = run.Process.Kill(); _ = run.Wait() })
	c := daemon.Config{Root: h.root, Home: h.home, Executable: helper}
	var before daemon.Record
	deadline := time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		before, _ = daemon.Status(c)
		if before.Running && before.Jobs {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !before.Running || !before.Jobs {
		t.Fatalf("timed out waiting for helper with jobs: %+v", before)
	}
	holdDone := make(chan error, 1)
	go func() { holdDone <- daemonRequest(before.Socket, "hold") }()
	deadline = time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(h.root, "daemon", "hold-started")); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(h.root, "daemon", "hold-started")); err != nil {
		t.Fatalf("timed out waiting for hold request to dispatch: %v", err)
	}
	candidate := helper + ".new"
	copyDaemonBinary(t, cachedDaemonHelperReplacement.binary(t, "../internal/daemon/testdata/exithelper", "-ldflags=-buildid=d1b-helper-swap"), candidate)
	if err := os.Rename(candidate, helper); err != nil {
		t.Fatal(err)
	}
	type upgradeResult struct {
		record daemon.Record
		err    error
	}
	checkDone := make(chan upgradeResult, 1)
	go func() {
		for {
			record, err := daemon.CheckUpgrade(c)
			if err == nil && !record.UpgradeStarted {
				time.Sleep(20 * time.Millisecond)
				continue
			}
			checkDone <- upgradeResult{record, err}
			return
		}
	}()
	deadline = time.Now().Add(45 * time.Second)
	for {
		select {
		case result := <-checkDone:
			t.Fatalf("upgrade passed in-flight work: %+v %v", result.record, result.err)
		default:
		}
		conn, err := net.DialTimeout("unix", before.Socket, 5*time.Second)
		if err == nil {
			_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
			var hello struct {
				Accepting bool `json:"accepting"`
			}
			err = json.NewDecoder(conn).Decode(&hello)
			conn.Close()
			if err == nil && !hello.Accepting {
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for upgrade to stop accepting requests: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	data, err := os.ReadFile(filepath.Join(h.root, "daemon", "canonical.json"))
	if err != nil {
		t.Fatal(err)
	}
	var published daemon.Record
	if err := json.Unmarshal(data, &published); err != nil || published.Generation != 1 {
		t.Fatalf("daemon changed generation before request finished: %+v %v", published, err)
	}
	if err := os.WriteFile(filepath.Join(h.root, "daemon", "hold-release"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := <-holdDone; err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-checkDone:
		if result.err != nil || !result.record.UpgradeStarted {
			t.Fatalf("upgrade was not started after request: %+v %v", result.record, result.err)
		}
	case <-time.After(45 * time.Second):
		t.Fatal("timed out waiting for upgrade after request")
	}
	deadline = time.Now().Add(45 * time.Second)
	var after daemon.Record
	for time.Now().Before(deadline) {
		after, _ = daemon.Status(c)
		if after.Generation == 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if after.Generation != 2 || after.PID != before.PID || !after.Jobs {
		t.Fatalf("timed out waiting for helper upgrade: before=%+v after=%+v", before, after)
	}
	var starts []byte
	deadline = time.Now().Add(45 * time.Second)
	for time.Now().Before(deadline) {
		starts, _ = os.ReadFile(filepath.Join(h.root, "daemon", "job-starts"))
		if len(starts) >= 2 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(starts) < 2 {
		t.Fatalf("timed out waiting for jobs to restart: starts=%q", starts)
	}
	if err := daemonRequest(after.Socket, "spawn-child"); err != nil {
		t.Fatal(err)
	}
	pidText, err := os.ReadFile(filepath.Join(h.root, "daemon", "child-pid"))
	if err != nil {
		t.Fatal(err)
	}
	childPID, err := strconv.Atoi(string(pidText))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(childPID, syscall.SIGKILL) })
	if err := run.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = run.Wait()
	if err := syscall.Kill(childPID, 0); err != nil {
		t.Fatalf("child did not outlive daemon: %v", err)
	}
	if conn, err := net.DialTimeout("unix", after.Socket, 100*time.Millisecond); err == nil {
		conn.Close()
		t.Fatal("listener leaked to child")
	}
	for _, name := range []string{"canonical.lock", "jobs.lock"} {
		lock, err := os.OpenFile(filepath.Join(h.root, "daemon", name), os.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
			lock.Close()
			t.Fatalf("%s leaked to child: %v", name, err)
		}
		lock.Close()
	}
}

func TestDaemonBadHandoffFallsBackToLockedStart(t *testing.T) {
	for _, missing := range []bool{false, true} {
		name := "wrong-inode"
		if missing {
			name = "missing-fd"
		}
		t.Run(name, func(t *testing.T) {
			h := newDaemonHarness(t, "")
			wrong, err := os.CreateTemp(t.TempDir(), "wrong-lock")
			if err != nil {
				t.Fatal(err)
			}
			defer wrong.Close()
			listenerFD := 999999
			files := []*os.File{wrong}
			if !missing {
				otherDir, err := os.MkdirTemp("/tmp", "qm-handoff-")
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.RemoveAll(otherDir) })
				other, err := net.ListenUnix("unix", &net.UnixAddr{Name: filepath.Join(otherDir, "other.sock"), Net: "unix"})
				if err != nil {
					t.Fatal(err)
				}
				defer other.Close()
				file, err := other.File()
				if err != nil {
					t.Fatal(err)
				}
				defer file.Close()
				files = append(files, file)
				listenerFD = 4
			}
			handoff := fmt.Sprintf(`{"root":%q,"identity":"canonical","generation":1,"lock_fd":3,"listener_fd":%d}`, h.root, listenerFD)
			run := exec.Command(h.bin, "daemon", "run", "--idle-grace=10m")
			run.Env = append(h.env, "QUESTMASTER_DAEMON_HANDOFF="+handoff)
			run.ExtraFiles = files
			if err := run.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = run.Process.Kill(); _ = run.Wait() })
			deadline := time.Now().Add(5 * time.Second)
			var status map[string]any
			for time.Now().Before(deadline) {
				status, _ = h.command("daemon", "status")
				if status["running"] == true {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			if status["running"] != true || status["generation"] != float64(1) || status["pid"] != float64(run.Process.Pid) {
				t.Fatalf("bad handoff did not start normally: %+v", status)
			}
			lock, err := os.OpenFile(filepath.Join(h.root, "daemon", "canonical.lock"), os.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer lock.Close()
			if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
				t.Fatalf("normal start did not hold the lifetime lock: %v", err)
			}
			h.must("daemon", "stop")
			h.waitStopped()
		})
	}
}

func TestDaemonEnvironmentFromPollutedPaneReachesBothSessionMutations(t *testing.T) {
	h := newDaemonHarness(t, "")
	helper := filepath.Join(t.TempDir(), "qm-helper")
	copyDaemonBinary(t, cachedDaemonHelper.binary(t, "../internal/daemon/testdata/exithelper"), helper)
	link := filepath.Join(h.home, ".local", "bin", "questmaster")
	if err := os.Remove(link); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(helper, link); err != nil {
		t.Fatal(err)
	}
	bin := filepath.Join(t.TempDir(), "captured-bin")
	if err := os.Mkdir(bin, 0o700); err != nil {
		t.Fatal(err)
	}
	project := filepath.Join(t.TempDir(), "project")
	if err := os.Mkdir(project, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, script := range map[string]string{
		"zoxide": "#!/bin/sh\nprintf '%s\\n' '" + project + "'\n",
		"codex":  "#!/bin/sh\nexit 0\n",
	} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	codexHome := filepath.Join(t.TempDir(), "codex-home")
	loginFile := filepath.Join(t.TempDir(), "login-env")
	login := fmt.Sprintf("PATH=%s:/usr/local/bin:/usr/bin\x00CODEX_HOME=%s\x00TMUX_PANE=bad\x00TERM=bad\x00", bin, codexHome)
	if err := os.WriteFile(loginFile, []byte(login), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(h.root, "daemon"), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"work", "release-drain"} {
		if err := os.WriteFile(filepath.Join(h.root, "daemon", name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	run := exec.Command(helper, "daemon", "run")
	run.Env = append(h.env,
		"SHELL=/bin/sh", "SSH_AUTH_SOCK=/tmp/agent.sock", "PATH=/pane/odd",
		"CLAUDECODE=pane", "TMUX=pane", "TERM=xterm", "QUESTMASTER_SESSION=qm-pane",
		"QUESTMASTER_QM=/pane/qm", "QUESTMASTER_TEST_LOGIN_ENV_FILE="+loginFile)
	if err := run.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = run.Process.Kill(); _ = run.Wait() })
	c := daemon.Config{Root: h.root, Home: h.home, Executable: helper}
	deadline := time.Now().Add(5 * time.Second)
	var record daemon.Record
	for time.Now().Before(deadline) {
		record, _ = daemon.Status(c)
		if record.Running {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !record.Running {
		t.Fatal("helper daemon did not start")
	}
	call := func(method string, data any) map[string]any {
		t.Helper()
		conn, err := net.DialTimeout("unix", record.Socket, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		dec := json.NewDecoder(conn)
		var greeting map[string]any
		if err := dec.Decode(&greeting); err != nil {
			t.Fatal(err)
		}
		if err := json.NewEncoder(conn).Encode(map[string]any{"method": method, "data": data}); err != nil {
			t.Fatal(err)
		}
		var reply struct {
			OK    bool           `json:"ok"`
			Data  map[string]any `json:"data"`
			Error string         `json:"error"`
		}
		if err := dec.Decode(&reply); err != nil || !reply.OK {
			t.Fatalf("%s: %+v %v", method, reply, err)
		}
		return reply.Data
	}
	startEnv := call("start", map[string]any{"title": "environment"})
	spawnEnv := call("spawn", map[string]any{"master_id": "qm-demo", "title": "environment"})
	if !reflect.DeepEqual(startEnv, spawnEnv) {
		t.Fatalf("start/spawn child environments differ: start=%+v spawn=%+v", startEnv, spawnEnv)
	}
	prefix := filepath.Join(h.root, "daemon", "bin", "canonical")
	if startEnv["SSH_AUTH_SOCK"] != "/tmp/agent.sock" || startEnv["CODEX_HOME"] != codexHome ||
		startEnv["QUESTMASTER_APP"] != "1" || startEnv["QUESTMASTER_STATE_ROOT"] != h.root ||
		startEnv["QUESTMASTER_PATH_PREFIX"] != prefix || startEnv["QUESTMASTER_BIN"] != filepath.Join(h.root, "bin", "current", "qm") ||
		startEnv["zoxide"] != filepath.Join(bin, "zoxide") || startEnv["codex"] != filepath.Join(bin, "codex") {
		t.Fatalf("captured child environment=%+v", startEnv)
	}
	wantHelper, err := filepath.EvalSymlinks(helper)
	if err != nil {
		t.Fatal(err)
	}
	stableBin, _ := startEnv["QUESTMASTER_BIN"].(string)
	if got, err := filepath.EvalSymlinks(stableBin); err != nil || got != wantHelper {
		t.Fatalf("QUESTMASTER_BIN resolves to %q (%v), want the daemon executable %q", got, err, wantHelper)
	}
	for _, key := range []string{"CLAUDECODE", "TMUX", "TERM", "QUESTMASTER_SESSION", "QUESTMASTER_QM"} {
		if startEnv[key] != "" {
			t.Fatalf("%s leaked into child: %+v", key, startEnv)
		}
	}
	if path := startEnv["PATH"].(string); !strings.HasPrefix(path, prefix+":") || strings.Contains(path, "/pane/odd") {
		t.Fatalf("child PATH=%q", path)
	}
	shims, err := os.ReadFile(filepath.Join(prefix, "qm"))
	if err != nil || !strings.Contains(string(shims), filepath.Join(h.root, "bin", "current", "qm")) {
		t.Fatalf("canonical shim does not target the stable executable: %q %v", shims, err)
	}
	suggest := call("dir_suggest", map[string]any{"query": "project"})
	if !strings.Contains(fmt.Sprint(suggest["suggestions"]), project) {
		t.Fatalf("captured zoxide did not answer dir_suggest: %+v", suggest)
	}
	if err := run.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = run.Wait()
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
