//go:build linux || darwin

package state

import (
	"strings"
	"testing"
)

func TestNormalizeToolCommand(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name    string
		command string
		want    string
	}{
		{name: "empty", command: "", want: ""},
		{name: "whitespace", command: "  \n\t", want: ""},
		{name: "environment assignment", command: "FOO=bar go test ./...", want: "go test"},
		{name: "multiple assignments", command: "FOO=bar BAZ=1 /usr/bin/git status", want: "git status"},
		{name: "absolute env wrapper", command: "/usr/bin/env FOO=bar /usr/bin/go test ./...", want: "go test"},
		{name: "sudo and env wrappers", command: "sudo env FOO=bar go test ./...", want: "go test"},
		{name: "timeout wrapper", command: "timeout 15 sleep 6", want: "sleep"},
		{name: "nice wrapper", command: "nice -n 5 /usr/bin/go test ./...", want: "go test"},
		{name: "wrapper chain", command: "env FOO=bar time command go test ./...", want: "go test"},
		{name: "all wrappers", command: "FOO=bar sudo -u alice timeout 3s nice -n 5 exec -a wrapped nohup env BAR=1 /usr/bin/npm run build", want: "npm run"},
		{name: "cd and and", command: "cd /tmp && npm run build", want: "npm run"},
		{name: "cd semicolon", command: "cd '/tmp/my repo'; /usr/bin/git status", want: "git status"},
		{name: "chained cd commands", command: "cd /tmp && cd repo; go test ./...", want: "go test"},
		{name: "pipeline first command", command: "go test ./... | tee test.log && echo done", want: "go test"},
		{name: "and chain first command", command: "sleep 6 && go test ./...", want: "sleep"},
		{name: "program basename", command: "/usr/bin/git status --short", want: "git status"},
		{name: "npm subcommand", command: "npm run build", want: "npm run"},
		{name: "flag is not subcommand", command: "ls -la", want: "ls"},
		{name: "path is not subcommand", command: "go ./...", want: "go"},
		{name: "number is not subcommand", command: "go 123", want: "go"},
		{name: "quoted word is not subcommand", command: `go "test"`, want: "go"},
		{name: "uppercase word is not subcommand", command: "go TEST", want: "go"},
		{name: "quoted program", command: `"/usr/bin/git" status`, want: "git status"},
		{name: "long input retains leading key", command: "go test " + strings.Repeat("x", maxToolCommandInputBytes), want: "go test"},
		{name: "cd without remainder", command: "cd /tmp", want: ""},
		{name: "overlong key", command: strings.Repeat("a", maxToolCommandKeyBytes+1), want: ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := NormalizeToolCommand(tc.command); got != tc.want {
				t.Fatalf("NormalizeToolCommand(%q) = %q, want %q", tc.command, got, tc.want)
			}
		})
	}
}
