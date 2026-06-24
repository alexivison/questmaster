package cmd

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

func cleanDisplayColorArg(color string) (string, error) {
	color = strings.ToLower(strings.TrimSpace(color))
	if color == "" {
		return "", nil
	}
	if state.IsDisplayColor(color) {
		return color, nil
	}
	return "", fmt.Errorf("invalid color %q (want one of %s, or empty to clear)", color, strings.Join(state.DisplayColorOptions(), ", "))
}
