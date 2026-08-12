package cmd

import (
	"context"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func (p openCodePatch) completeNativeSessionUpdate() bool {
	return p.hasURL && p.serverURL != "" && p.hasPID && p.serverPID > 0 && p.sessionID != "" &&
		p.hasAgent && p.hasUpdateSeq && p.updateSeq > 0
}

func openCodeNativeSessionUpdateMatchesManifest(ctx context.Context, r *HookRunner, manifest state.Manifest, patch openCodePatch) bool {
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
	current, ok := manifest.OpenCodeNativeIdentity()
	if !ok {
		return true
	}
	if current.PID != patch.serverPID {
		return true
	}
	return patch.updateSeq > current.Sequence
}

func openCodeManifestHasNativeIdentity(manifest state.Manifest) bool {
	_, ok := manifest.OpenCodeNativeIdentity()
	return ok
}

func openCodeNativeLifecycleMatchesManifest(manifest state.Manifest, patch openCodePatch) bool {
	identity, ok := manifest.OpenCodeNativeIdentity()
	if !ok {
		return false
	}
	return patch.hasURL && patch.serverURL != "" && patch.hasPID && patch.serverPID > 0 && patch.sessionID != "" &&
		identity.ServerURL == patch.serverURL && identity.PID == patch.serverPID && identity.SessionID == patch.sessionID
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
	persistRuntimeResumeID(stderr, sessionID, openCodeSessionID)
}

func updateNativeOpenCodeIdentity(ctx context.Context, r *HookRunner, stderr io.Writer, sessionID string, patch openCodePatch) (bool, error) {
	if r.Store == nil {
		return false, nil
	}
	tmuxPane := strings.TrimSpace(os.Getenv("TMUX_PANE"))
	nextCwd, _ := os.Getwd()
	accepted := false
	tagPrimary := false
	err := r.Store.Update(sessionID, func(manifest *state.Manifest) {
		if !openCodeNativeSessionUpdateMatchesManifest(ctx, r, *manifest, patch) {
			return
		}
		plan := mutateResumeID(manifest, "opencode_session_id", patch.sessionID, "opencode", tmuxPane, nextCwd)
		if !plan.accepted {
			return
		}
		manifest.SetOpenCodeNativeIdentity(state.OpenCodeNative{
			ServerURL: patch.serverURL,
			SessionID: patch.sessionID,
			Agent:     patch.agent,
			PID:       patch.serverPID,
			Sequence:  patch.updateSeq,
		})
		accepted = true
		tagPrimary = plan.tagPrimary
	})
	if err != nil || !accepted {
		return false, err
	}
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
	persistRuntimeResumeID(stderr, sessionID, patch.sessionID)
	return true, nil
}

func persistRuntimeResumeID(stderr io.Writer, sessionID, value string) {
	dir := filepath.Join("/tmp", sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: create runtime dir: %v\n", err)
		return
	}
	if err := os.WriteFile(filepath.Join(dir, "opencode-session-id"), []byte(value+"\n"), 0o644); err != nil {
		fmt.Fprintf(stderr, "questmaster hook opencode: write runtime resume id: %v\n", err)
	}
}
