//go:build linux || darwin

package message

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func (s *Service) deliverCodex(ctx context.Context, m state.Manifest, message string) error {
	thread := m.ExtraString("codex_thread_id")
	if thread == "" {
		for _, agent := range m.Agents {
			if agent.Role == primaryRole && agent.Name == "codex" {
				thread = agent.ResumeID
				break
			}
		}
	}
	if thread == "" {
		return fmt.Errorf("%w: Codex thread id missing", errNativeUnavailable)
	}
	if state.SanitizeResumeID(thread) != thread {
		return fmt.Errorf("invalid Codex thread id")
	}
	binary, err := exec.LookPath("codex")
	if err != nil {
		return fmt.Errorf("%w: Codex binary unavailable: %v", errNativeUnavailable, err)
	}
	checkCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	version, err := exec.CommandContext(checkCtx, binary, "app-server", "daemon", "version").Output()
	if err != nil {
		return fmt.Errorf("%w: Codex daemon unavailable: %v", errNativeUnavailable, err)
	}
	var daemon struct {
		Status string `json:"status"`
	}
	if json.Unmarshal(version, &daemon) != nil || daemon.Status != "running" {
		return fmt.Errorf("%w: Codex daemon is not running", errNativeUnavailable)
	}
	output, err := exec.CommandContext(ctx, binary, "queue", "--thread", thread, "--message", message).CombinedOutput()
	if err != nil {
		return fmt.Errorf("Codex queue failed: %w: %s", err, strings.TrimSpace(string(output)))
	}
	if !strings.HasPrefix(string(output), "Queued message ") {
		return fmt.Errorf("Codex queue returned no acceptance receipt: %s", strings.TrimSpace(string(output)))
	}
	return nil
}
