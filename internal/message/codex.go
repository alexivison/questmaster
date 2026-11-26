//go:build linux || darwin

package message

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
)

func (s *Service) deliverCodex(ctx context.Context, m state.Manifest, text string, beforeSend func() error) error {
	dir, err := m.RuntimeDirOrLegacy()
	if err != nil {
		return err
	}
	enabled, err := codexnative.Enabled(dir)
	if err != nil {
		return err
	}
	if !enabled {
		return errNativeUnavailable
	}
	threadID := m.ExtraString("codex_thread_id")
	for _, a := range m.Agents {
		if a.Name == "codex" && a.ResumeID != "" {
			threadID = a.ResumeID
			break
		}
	}
	if err := codexnative.SendWithCheck(ctx, dir, threadID, text, beforeSend); err != nil {
		return fmt.Errorf("Codex native delivery: %w", err)
	}
	return nil
}
