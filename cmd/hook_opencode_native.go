package cmd

import (
	"context"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func (p openCodePatch) completeNativeSessionUpdate() bool {
	return p.hasURL && p.serverURL != "" && p.hasPID && p.serverPID > 0 && p.sessionID != "" &&
		p.hasAgent && p.hasUpdateSeq && p.updateSeq > 0
}

func openCodeNativeSessionUpdateMatchesPane(ctx context.Context, r *HookRunner, pane state.PaneState, patch openCodePatch) bool {
	if !patch.completeNativeSessionUpdate() || r.TmuxClient == nil {
		return false
	}
	target := strings.TrimSpace(os.Getenv("TMUX_PANE"))
	if target == "" {
		return false
	}
	pid, _, err := r.TmuxClient.PaneIdentity(ctx, target)
	if err != nil || pid != patch.serverPID {
		return false
	}
	if pane.OpenCodeServerURL == "" || pane.OpenCodePID <= 0 || pane.OpenCodeSessionID == "" {
		return true
	}
	if pane.OpenCodePID != patch.serverPID {
		return true
	}
	return patch.updateSeq > pane.OpenCodeSessionUpdateSeq
}

func openCodePaneHasNativeIdentity(pane state.PaneState) bool {
	return pane.OpenCodeServerURL != "" && pane.OpenCodePID > 0 && pane.OpenCodeSessionID != ""
}

func openCodeNativeLifecycleMatchesPane(pane state.PaneState, patch openCodePatch) bool {
	return patch.hasURL && patch.serverURL != "" && patch.hasPID && patch.serverPID > 0 && patch.sessionID != "" &&
		pane.OpenCodeServerURL == patch.serverURL && pane.OpenCodePID == patch.serverPID &&
		pane.OpenCodeSessionID == patch.sessionID
}

func openCodeNativeMetadata(event openCodeEvent) (string, bool, int, bool, uint64, bool, bool) {
	metadata, ok := event.Properties["metadata"].(map[string]interface{})
	if !ok {
		return "", false, 0, false, 0, false, false
	}
	questmaster, ok := metadata["questmaster"].(map[string]interface{})
	if !ok {
		return "", false, 0, false, 0, false, false
	}
	serverURL, hasURL := questmaster["server_url"].(string)
	if hasURL {
		serverURL = strings.TrimSpace(serverURL)
	}
	pidValue, hasPID := openCodePositiveInteger(questmaster["pid"], 1<<31-1)
	if !hasPID {
		return serverURL, hasURL, 0, false, 0, false, true
	}
	seqValue, hasSeq := openCodePositiveInteger(questmaster["session_update_seq"], 1<<53-1)
	if !hasSeq {
		return serverURL, hasURL, int(pidValue), true, 0, false, true
	}
	return serverURL, hasURL, int(pidValue), true, uint64(seqValue), true, true
}

func openCodePositiveInteger(value interface{}, max float64) (float64, bool) {
	n, ok := value.(float64)
	if !ok {
		return 0, false
	}
	return n, n == math.Trunc(n) && n > 0 && n <= max
}

func openCodeSessionAgent(event openCodeEvent) (string, bool) {
	info, ok := event.Properties["info"].(map[string]interface{})
	if !ok {
		return "", false
	}
	agent, ok := info["agent"].(string)
	agent = strings.TrimSpace(agent)
	return agent, ok && agent != ""
}

func captureOpenCodeSessionID(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID, openCodeSessionID string) {
	captureResumeID(ctx, r, stderr, sessionID, "opencode_session_id", "OPENCODE_SESSION_ID", openCodeSessionID, "opencode")
	persistRuntimeResumeID(stderr, sessionID, "opencode-session-id", openCodeSessionID, "opencode")
}

func updateNativeOpenCodeIdentity(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID string, now time.Time, patch openCodePatch, ev state.StateEvent) (bool, error) {
	if r.UpdateOpenCodeIdentity == nil {
		return false, nil
	}
	tmuxPane := strings.TrimSpace(os.Getenv("TMUX_PANE"))
	nextCwd, _ := os.Getwd()
	tagPrimary := false
	return r.UpdateOpenCodeIdentity(sessionID, ev, func(manifest *state.Manifest, ss *state.SessionState) bool {
		accepted, changed := mutateOpenCodePane(ctx, r, ss, now, patch)
		if !accepted {
			return false
		}
		plan := mutateResumeID(manifest, "opencode_session_id", patch.sessionID, "opencode", tmuxPane, nextCwd)
		if !plan.accepted {
			return false
		}
		tagPrimary = plan.tagPrimary
		return changed
	}, func() error {
		if tagPrimary && r.TmuxClient != nil {
			if err := r.TmuxClient.SetPaneOption(ctx, tmuxPane, tmux.PaneRoleOption, tmux.RolePrimary); err != nil {
				fmt.Fprintf(stderr, "questmaster hook opencode: tag adopted pane: %v\n", err)
			}
		}
		if r.TmuxClient != nil {
			if err := r.TmuxClient.SetEnvironment(ctx, sessionID, "OPENCODE_SESSION_ID", patch.sessionID); err != nil {
				fmt.Fprintf(stderr, "questmaster hook opencode: set tmux env: %v\n", err)
			}
		}
		persistRuntimeResumeID(stderr, sessionID, "opencode-session-id", patch.sessionID, "opencode")
		return nil
	})
}

func persistRuntimeResumeID(stderr io.Writer, sessionID, fileName, value, agent string) {
	if value == "" {
		return
	}
	dir := filepath.Join("/tmp", sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: create runtime dir: %v\n", agent, err)
		return
	}
	path := filepath.Join(dir, fileName)
	body := []byte(value + "\n")
	if existing, err := os.ReadFile(path); err == nil && string(existing) == string(body) {
		return
	}
	tmp, err := os.CreateTemp(dir, "."+fileName+"-*")
	if err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: create runtime resume id: %v\n", agent, err)
		return
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.Write(body); err != nil {
		_ = tmp.Close()
		fmt.Fprintf(stderr, "questmaster hook %s: write runtime resume id: %v\n", agent, err)
		return
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		fmt.Fprintf(stderr, "questmaster hook %s: chmod runtime resume id: %v\n", agent, err)
		return
	}
	if err := tmp.Close(); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: close runtime resume id: %v\n", agent, err)
		return
	}
	if err := os.Rename(tmpPath, path); err != nil {
		fmt.Fprintf(stderr, "questmaster hook %s: write runtime resume id: %v\n", agent, err)
	}
}
