package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSwiftPaletteIsCurrent(t *testing.T) {
	t.Parallel()
	path := filepath.Join("..", "..", "..", "app", "Sources", "Core", "Rendering", "ThemePalette.swift")
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != render() {
		t.Fatal("Swift palette differs from the shared source; run go generate ./internal/palette")
	}
}
