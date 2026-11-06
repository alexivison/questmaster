package tmuxconfig_test

import (
	"testing"

	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func prepareConfig(t *testing.T, root string) error {
	t.Helper()
	tmuxtest.StubQuestmaster(t)
	return tmuxconfig.Prepare(root)
}
