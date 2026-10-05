//go:build linux || darwin

package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSendIsMessagingHelpPath(t *testing.T) {
	help := runCmd(t, setupStore(t), messagingRunner(), "--help")
	if !strings.Contains(help, "  send ") || strings.Contains(help, "  relay ") || strings.Contains(help, "  report ") || strings.Contains(help, "  broadcast ") {
		t.Fatalf("messaging command help = %q", help)
	}
}

func TestSendDirectPreservesSender(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-worker")
	out := runCmd(t, store, runner, "send", "qm-worker", "hello")
	if !strings.Contains(out, `"recipient": "qm-worker"`) || len(runner.sends) != 1 || runner.sends[0] != "[FROM:qm-master] hello" {
		t.Fatalf("send output = %q, payloads = %v", out, runner.sends)
	}
}

func TestSendMasterAndParentIDUseReportAttribution(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-worker")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-master")
	for _, recipient := range []string{"master", "qm-master"} {
		out := runCmd(t, store, runner, "send", recipient, "done")
		if !strings.Contains(out, `"recipient": "`+recipient+`"`) {
			t.Fatalf("send %s output = %q", recipient, out)
		}
	}
	if len(runner.sends) != 2 || runner.sends[0] != "[WORKER:qm-worker] done" || runner.sends[1] != runner.sends[0] {
		t.Fatalf("report payloads = %v", runner.sends)
	}
}

func TestSendAllBroadcastsFromMaster(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")
	runner := newSendCaptureRunner("qm-w1", "qm-w2")
	out := runCmd(t, store, runner, "send", "all", "hello")
	if !strings.Contains(out, `"registered": 2`) || !strings.Contains(out, `"submitted": 2`) {
		t.Fatalf("broadcast output = %q", out)
	}
	if len(runner.sends) != 2 || runner.sends[0] != "[FROM:qm-master] hello" || runner.sends[1] != runner.sends[0] {
		t.Fatalf("broadcast payloads = %v", runner.sends)
	}
}

func TestSendReadsMessageFile(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	path := filepath.Join(t.TempDir(), "message.txt")
	if err := os.WriteFile(path, []byte("from file"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := newSendCaptureRunner("qm-worker")
	runCmd(t, store, runner, "send", "qm-worker", "--message-file", path)
	if len(runner.sends) != 1 || runner.sends[0] != "[FROM:qm-master] from file" {
		t.Fatalf("file payloads = %v", runner.sends)
	}
	runner.sends = nil
	runCmdInput(t, store, runner, strings.NewReader("from stdin"), "send", "qm-worker", "--message-file", "-")
	if len(runner.sends) != 1 || runner.sends[0] != "[FROM:qm-master] from stdin" {
		t.Fatalf("stdin payloads = %v", runner.sends)
	}
}

func TestReportRejectsDifferentExplicitSessionInWorker(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-worker")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-master")
	_, err := runCmdErr(t, store, runner, "report", "qm-master", "done")
	if err == nil || !strings.Contains(err.Error(), "does not match current session") || len(runner.sends) != 0 {
		t.Fatalf("report mismatch error = %v, sends = %v", err, runner.sends)
	}
	runCmd(t, store, runner, "report", "qm-worker", "done")
	if len(runner.sends) != 1 || runner.sends[0] != "[WORKER:qm-worker] done" {
		t.Fatalf("matching legacy report payloads = %v", runner.sends)
	}
}
