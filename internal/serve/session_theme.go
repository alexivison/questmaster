package serve

import (
	"context"

	"github.com/alexivison/questmaster/internal/sessiontheme"
)

func (s *Server) syncThemeAfter(ctx context.Context, result any, err error) (any, error) {
	if err != nil {
		return result, err
	}
	return result, sessiontheme.Sync(ctx, s.mutationStore(), s.TmuxRouter, "")
}
