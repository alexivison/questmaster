package serve

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func (s *Server) tmuxRoutes(ctx context.Context, req Request) ([]tmuxroute.RouteRecord, error) {
	if s.TmuxRouter == nil {
		return nil, fmt.Errorf("tmux routes are unavailable")
	}
	var params struct {
		SessionIDs []string `json:"session_ids"`
		Live       bool     `json:"live"`
	}
	if len(req.Data) > 0 {
		if err := json.Unmarshal(req.Data, &params); err != nil {
			return nil, fmt.Errorf("decode tmux.routes data: %w", err)
		}
	}
	return s.TmuxRouter.Routes(ctx, params.SessionIDs, params.Live)
}
