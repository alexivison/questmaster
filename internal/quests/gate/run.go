// Package gate runs a quest's auto gates and records their observed results.
// qm is the verifier of auto gates: it runs the check and reads the verdict.
// The agent never passes a gate; the human checks toggle gates and stamps done.
// This stage runs cmd:<shell> checks only — no github:*, no typecheck/lint/
// coverage sugar, no repo-level config. Results are transient and observed, so
// they live in a runtime sidecar (sidecar.go), never in the quest JSON.
package gate

import (
	"bytes"
	"errors"
	"os/exec"
	"strings"
	"time"
)

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

// RunCheck runs a gate's check in worktree and classifies the verdict. Only the
// cmd:<shell> grammar is executed; any other check is reported as misconfigured
// (StatusError) rather than silently passing. The shell runs with worktree as
// its working directory; the runner fabricates nothing — it only runs the
// command the quest authored.
func RunCheck(name, check, worktree string) Result {
	r := Result{Gate: name, RanAt: time.Now().UTC()}

	shell, ok := strings.CutPrefix(check, "cmd:")
	if !ok {
		r.Status = StatusError
		r.Output = "unsupported check " + check + " (this stage runs cmd:<shell> only)"
		return r
	}
	shell = strings.TrimSpace(shell)
	if shell == "" {
		r.Status = StatusError
		r.Output = "empty cmd: check"
		return r
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
		return r
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
		return r
	}

	// The shell itself could not be started.
	r.Status = StatusError
	if r.Output == "" {
		r.Output = err.Error()
	}
	return r
}
