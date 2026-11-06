package serve

import (
	"context"
	"fmt"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func (s *Server) tmuxConfigRoot() string {
	if s.Snapshotter == nil {
		return state.StateRoot()
	}
	return s.Snapshotter.StateRoot()
}

func (s *Server) tmuxConfigClient() (*tmux.Client, error) {
	if s.TmuxRouter == nil {
		return nil, fmt.Errorf("tmux routes are unavailable")
	}
	label, err := tmux.EffectiveLabel()
	if err != nil {
		return nil, err
	}
	handle, err := s.TmuxRouter.Route(state.Manifest{TmuxServer: state.TmuxServer(label)})
	if err != nil {
		return nil, err
	}
	return handle.Client(), nil
}

func (s *Server) tmuxConfig(ctx context.Context) (tmuxconfig.StatusResult, error) {
	client, err := s.tmuxConfigClient()
	if err != nil {
		return tmuxconfig.StatusResult{}, err
	}
	return tmuxconfig.Status(ctx, client, s.tmuxConfigRoot())
}

func (s *Server) tmuxConfigCheck(ctx context.Context) (tmuxconfig.CheckResult, error) {
	label, err := tmux.EffectiveLabel()
	if err != nil {
		return tmuxconfig.CheckResult{}, err
	}
	paths := tmuxconfig.PathsForLabel(s.tmuxConfigRoot(), label)
	if err := tmuxconfig.EnsureGenerated(s.tmuxConfigRoot()); err != nil {
		return tmuxconfig.CheckResult{}, err
	}
	errors, err := tmuxconfig.Check(ctx, paths.Config, paths.Enforced)
	if err != nil {
		return tmuxconfig.CheckResult{}, err
	}
	return tmuxconfig.CheckResult{OK: len(errors) == 0, Errors: errors, EffectiveLabel: label}, nil
}

func (s *Server) tmuxConfigReload(ctx context.Context) (tmuxconfig.ReloadResult, error) {
	client, err := s.tmuxConfigClient()
	if err != nil {
		return tmuxconfig.ReloadResult{}, err
	}
	return tmuxconfig.Reload(ctx, client, s.tmuxConfigRoot())
}

func (s *Server) tmuxServerRestart(ctx context.Context) (tmuxconfig.RestartResult, error) {
	client, err := s.tmuxConfigClient()
	if err != nil {
		return tmuxconfig.RestartResult{}, err
	}
	return tmuxconfig.RestartIfEmpty(ctx, client, s.tmuxConfigRoot())
}
