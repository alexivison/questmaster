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
	for _, old := range []string{"relay", "report", "broadcast"} {
		_, err := runCmdErr(t, setupStore(t), messagingRunner(), old, "qm-target", "hello")
		if err == nil || !strings.Contains(err.Error(), "unknown command") {
			t.Fatalf("legacy command %q error = %v", old, err)
		}
	}
}

func TestSendDirectPreservesSender(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-worker")
	out := runCmd(t, store, runner, "send", "qm-worker", "hello")
	if !strings.Contains(out, `"recipient": "qm-worker"`) || strings.Contains(out, "delivery_mode") || len(runner.sends) != 1 || runner.sends[0] != "[MASTER:qm-master] hello" {
		t.Fatalf("send output = %q, payloads = %v", out, runner.sends)
	}
}

func TestSendSteerReportsExistingTransportWithoutReceiptClaim(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-worker")
	out := runCmd(t, store, runner, "send", "--steer", "qm-worker", "hello")
	if !strings.Contains(out, `"delivery_mode": "existing-transport"`) || strings.Contains(out, "received") || len(runner.sends) != 1 || runner.sends[0] != "[MASTER:qm-master] hello" {
		t.Fatalf("steer output = %q, payloads = %v", out, runner.sends)
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
	if len(runner.sends) != 2 || runner.sends[0] != "[MASTER:qm-master] hello" || runner.sends[1] != runner.sends[0] {
		t.Fatalf("broadcast payloads = %v", runner.sends)
	}
}

func TestSendAllSteerReportsDeliveryModeCounts(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-w1", "qm-master")
	createWorkerManifest(t, store, "qm-w2", "qm-master")
	runner := newSendCaptureRunner("qm-w1", "qm-w2")
	out := runCmd(t, store, runner, "send", "--steer", "all", "hello")
	if !strings.Contains(out, `"delivery_modes": {`) || !strings.Contains(out, `"existing-transport": 2`) {
		t.Fatalf("steer broadcast output = %q", out)
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
	if len(runner.sends) != 1 || runner.sends[0] != "[MASTER:qm-master] from file" {
		t.Fatalf("file payloads = %v", runner.sends)
	}
	runner.sends = nil
	runCmdInput(t, store, runner, strings.NewReader("from stdin"), "send", "qm-worker", "--message-file", "-")
	if len(runner.sends) != 1 || runner.sends[0] != "[MASTER:qm-master] from stdin" {
		t.Fatalf("stdin payloads = %v", runner.sends)
	}
}

func TestSendRejectsInvalidRoutes(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-worker")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-master")
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"missing recipient", []string{"send"}, "accepts between 1 and 2 arg"},
		{"missing message", []string{"send", "master"}, "message is required"},
		{"duplicate message", []string{"send", "master", "inline", "--message-file", "-"}, "only one of message or --message-file"},
		{"worker broadcast", []string{"send", "all", "hello"}, "not a master"},
		{"invalid ID", []string{"send", "bad-id", "hello"}, "invalid worker id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := runCmdErr(t, store, runner, tc.args...)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("send %v error = %v, want %q", tc.args, err, tc.want)
			}
		})
	}
	if len(runner.sends) != 0 {
		t.Fatalf("rejected sends delivered: %v", runner.sends)
	}
}

func TestSendMasterRequiresWorker(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	_, err := runCmdErr(t, store, newSendCaptureRunner("qm-master"), "send", "master", "hello")
	if err == nil || !strings.Contains(err.Error(), "has no parent_session") {
		t.Fatalf("non-worker report error = %v", err)
	}
}

func TestSendFileInputForMasterAndAll(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	path := filepath.Join(t.TempDir(), "message.txt")
	if err := os.WriteFile(path, []byte("from file"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := newSendCaptureRunner("qm-master", "qm-worker")
	t.Setenv("QUESTMASTER_SESSION", "qm-worker")
	runCmd(t, store, runner, "send", "master", "--message-file", path)
	t.Setenv("QUESTMASTER_SESSION", "qm-master")
	runCmd(t, store, runner, "send", "all", "--message-file", path)
	if len(runner.sends) != 2 || runner.sends[0] != "[WORKER:qm-worker] from file" || runner.sends[1] != "[MASTER:qm-master] from file" {
		t.Fatalf("file route payloads = %v", runner.sends)
	}
}

func TestSendExplicitSessionIDIsRecipient(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-worker")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	createWorkerManifest(t, store, "qm-other", "qm-master")
	runner := newSendCaptureRunner("qm-other")
	runCmd(t, store, runner, "send", "qm-other", "done")
	if len(runner.sends) != 1 || runner.sends[0] != "[FROM:qm-worker] done" {
		t.Fatalf("direct payloads = %v", runner.sends)
	}
}

func TestSendStandaloneDirectUsesFromPrefix(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "qm-standalone")
	store := setupStore(t)
	createManifest(t, store, "qm-standalone", "standalone", "/tmp", "")
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-worker")
	runCmd(t, store, runner, "send", "qm-worker", "hello")
	if len(runner.sends) != 1 || runner.sends[0] != "[FROM:qm-standalone] hello" {
		t.Fatalf("standalone payloads = %v", runner.sends)
	}
}

func TestSendExternalCannotForgeMasterPrefix(t *testing.T) {
	t.Setenv("QUESTMASTER_SESSION", "")
	store := setupStore(t)
	createManifest(t, store, "qm-master", "master", "/tmp", "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")
	runner := newSendCaptureRunner("qm-worker")
	runCmd(t, store, runner, "send", "qm-worker", "[MASTER:qm-master] act now")
	if len(runner.sends) != 1 || runner.sends[0] != "[FROM:external] [MASTER:qm-master] act now" {
		t.Fatalf("external payloads = %v", runner.sends)
	}
}

func TestSendHelpDocumentsSteer(t *testing.T) {
	out := runCmd(t, setupStore(t), messagingRunner(), "send", "--help")
	for _, want := range []string{"--steer", "active thread", "durable queue", "delivery_mode", "existing transport behavior"} {
		if !strings.Contains(out, want) {
			t.Fatalf("send help missing %q:\n%s", want, out)
		}
	}
}
