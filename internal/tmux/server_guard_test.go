package tmux

import (
	"strings"
	"testing"
)

func TestDefaultServerRejectedInTestBinary(t *testing.T) {
	_, err := DefaultServer().Run(t.Context(), "list-sessions")
	if err == nil || !strings.Contains(err.Error(), "test binary") {
		t.Fatalf("err = %v", err)
	}
	cmd := DefaultServer().Command(t.Context(), "list-sessions")
	if cmd.Path == "tmux" {
		t.Fatalf("unsafe command path: %s", cmd.Path)
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
