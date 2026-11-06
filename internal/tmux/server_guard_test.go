package tmux

import (
	"strings"
	"testing"
)

func TestDefaultServerRejectedInTestBinary(t *testing.T) {
	_, err := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf").Run(t.Context(), "list-sessions")
	if err == nil || !strings.Contains(err.Error(), "test binary") {
		t.Fatalf("err = %v", err)
	}
	cmd := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf").Command(t.Context(), "list-sessions")
	if cmd.Path == "tmux" {
		t.Fatalf("unsafe command path: %s", cmd.Path)
	}
}

func TestInvalidCreationSelectorNeverRunsTmux(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "bad label")
	server := DefaultServer("/tmp/user.conf", "/tmp/enforced.conf")
	if _, err := server.Run(t.Context(), "list-sessions"); err == nil || !strings.Contains(err.Error(), "QUESTMASTER_TMUX_LABEL") {
		t.Fatalf("invalid override error = %v", err)
	}
	if cmd := server.Command(t.Context(), "list-sessions"); cmd.Path == "tmux" || cmd.Args[2] == "" {
		t.Fatalf("unsafe tmux command = %+v", cmd)
	}
	if err := server.Command(t.Context(), "list-sessions").Run(); err == nil || !strings.Contains(err.Error(), "QUESTMASTER_TMUX_LABEL") {
		t.Fatalf("direct command error = %v", err)
	}
}

func TestNamedCreationNeedsBothConfigFiles(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "dev_test")
	for _, server := range []Server{DefaultServer("", "/tmp/enforced.conf"), DefaultServer("/tmp/user.conf", ""), {flag: "-L", name: "dev_test"}} {
		if _, err := server.Run(t.Context(), "list-sessions"); err == nil || !strings.Contains(err.Error(), "config") {
			t.Fatalf("missing config error = %v", err)
		}
	}
}

func TestRecordedNamedServerRejectedInTestBinary(t *testing.T) {
	server, err := NamedServerLabel("dev_override", "/tmp/user.conf", "/tmp/enforced.conf")
	if err != nil {
		t.Fatal(err)
	}
	_, err = server.Run(t.Context(), "list-sessions")
	if err == nil || !strings.Contains(err.Error(), "test binary") {
		t.Fatalf("err = %v", err)
	}
	if cmd := server.Command(t.Context(), "list-sessions"); cmd.Path == "tmux" {
		t.Fatalf("unsafe command path: %s", cmd.Path)
	}
}

func TestPrivateSocketAllowedInTestBinary(t *testing.T) {
	calls := installFakeTmux(t)
	if _, err := SocketServer("/tmp/qm-private/tmux.sock").Run(t.Context(), "list-sessions"); err != nil {
		t.Fatal(err)
	}
	if len(calls()) != 1 {
		t.Fatalf("private socket calls = %d", len(calls()))
	}
}
