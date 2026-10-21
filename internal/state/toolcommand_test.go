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
		{name: "wrapper chain", command: "env FOO=bar time /usr/bin/go test ./...", want: "go test"},
		{name: "supported wrappers", command: "FOO=bar sudo timeout 3s env BAR=1 /usr/bin/npm run build", want: "npm run"},
		{name: "cd and and", command: "cd /tmp && npm run build", want: "npm run"},
		{name: "cd semicolon", command: "cd '/tmp/my repo'; /usr/bin/git status", want: "git status"},
		{name: "cd newline", command: "cd app\nswift build", want: "swift build"},
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
		{name: "ls argument is not subcommand", command: "ls src", want: "ls"},
		{name: "cat argument is not subcommand", command: "cat notes", want: "cat"},
		{name: "echo argument is not subcommand", command: "echo hello", want: "echo"},
		{name: "grep argument is not subcommand", command: "grep foo", want: "grep"},
		{name: "rm argument is not subcommand", command: "rm build", want: "rm"},
		{name: "command substitution assignment", command: "FOO=$(git rev-parse HEAD) make", want: "make"},
		{name: "subshell command", command: "(cd app && swift build)", want: ""},
		{name: "brace group", command: "{ cd app; swift build; }", want: ""},
		{name: "shell comment", command: "# run go test", want: ""},
		{name: "shell function command", command: "prof()", want: ""},
		{name: "for loop", command: "for f in *.go; do go test \"$f\"; done", want: ""},
		{name: "while loop", command: "while true; do sleep 1; done", want: ""},
		{name: "until loop", command: "until ready; do sleep 1; done", want: ""},
		{name: "if statement", command: "if test -f x; then cat x; fi", want: ""},
		{name: "case statement", command: "case $x in a) echo a;; esac", want: ""},
		{name: "do keyword", command: "do echo hi; done", want: ""},
		{name: "then keyword", command: "then echo hi; fi", want: ""},
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
