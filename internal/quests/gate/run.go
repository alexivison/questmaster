// Package gate runs a quest's auto gates and records their observed results.
// qm is the verifier of auto gates: it runs the check and reads the verdict.
// The agent never passes a gate; the human checks toggle gates and stamps done.
// Supported auto gates are cmd:<shell> plus a small set of GitHub PR gates
// backed by structured gh JSON. Results are transient and observed, so they
// live in a runtime sidecar (sidecar.go), never in the quest JSON.
package gate

import (
	"bytes"
	"errors"
	"os/exec"
	"strings"
	"time"
)

const supportedCheckGrammar = "cmd:<shell> or github:{checks|checks-green|review-approved|pr-approved|pr-merged|merged}[:<pr-number-or-url>]"

// Status is the verdict of an auto-gate run.
type Status string

const (
	// StatusPass means the check ran and exited zero.
	StatusPass Status = "pass"
	// StatusFail means the check ran and exited nonzero — legitimately unmet.
	StatusFail Status = "fail"
	// StatusError means the check did not execute to a real verdict: a broken
	// or misconfigured check (command not found, not executable, unsupported
	// check type). It must never be mistaken for a real failure.
	StatusError Status = "error"
)

// Result is one auto-gate run's observed outcome.
type Result struct {
	Gate   string    `json:"gate"`
	Status Status    `json:"status"`
	Output string    `json:"output,omitempty"` // combined stdout+stderr (snippet)
	RanAt  time.Time `json:"ran_at"`
}

// Misconfigured reports whether the result is a broken check rather than a real
// failure — surfaced distinctly so it announces itself instead of masquerading
// as the gate being unmet.
func (r Result) Misconfigured() bool { return r.Status == StatusError }

// RunCheck runs a gate's check in worktree and classifies the verdict. The shell
// for cmd:<shell> checks and gh for github:* checks run with worktree as their
// working directory. The runner fabricates nothing; it only observes the check
// the quest authored.
func RunCheck(name, check, worktree string) Result {
	r := Result{Gate: name, RanAt: time.Now().UTC()}

	check = strings.TrimSpace(check)
	shell, ok := strings.CutPrefix(check, "cmd:")
	if ok {
		runCmdCheck(&r, shell, worktree)
		return r
	}

	if strings.HasPrefix(check, "github:") {
		runGitHubCheck(&r, check, worktree)
		return r
	}

	r.Status = StatusError
	r.Output = "unsupported check " + check + " (supported: " + supportedCheckGrammar + ")"
	return r
}

func runCmdCheck(r *Result, shell, worktree string) {
	shell = strings.TrimSpace(shell)
	if shell == "" {
		r.Status = StatusError
		r.Output = "empty cmd: check"
		return
	}

	cmd := exec.Command("sh", "-c", shell)
	cmd.Dir = worktree
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	err := cmd.Run()
	r.Output = buf.String()

	if err == nil {
		r.Status = StatusPass
		return
	}

	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		// The shell ran; the inner command's exit code is the verdict. 127
		// (command not found) and 126 (not executable) mean the check is
		// broken, not that the gate is unmet.
		switch exitErr.ExitCode() {
		case 126, 127:
			r.Status = StatusError
		default:
			r.Status = StatusFail
		}
		return
	}

	// The shell itself could not be started.
	r.Status = StatusError
	if r.Output == "" {
		r.Output = err.Error()
	}
}
