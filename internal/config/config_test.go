package config

import "testing"

func TestLoad_Defaults(t *testing.T) {
	t.Parallel()

	cfg := Load()

	if cfg.LogLevel != "info" {
		t.Fatalf("expected default log level 'info', got %q", cfg.LogLevel)
	}

	if cfg.RepoRoot != "" {
		t.Fatalf("expected empty RepoRoot when PARTY_REPO_ROOT unset, got %q", cfg.RepoRoot)
	}
}

func TestLoad_RepoRootFromEnv(t *testing.T) {
	t.Setenv("PARTY_REPO_ROOT", "/test/repo")

	cfg := Load()

	if cfg.RepoRoot != "/test/repo" {
		t.Fatalf("expected RepoRoot '/test/repo', got %q", cfg.RepoRoot)
	}
}

func TestLoad_LogLevelFromEnv(t *testing.T) {
	t.Setenv("PARTY_LOG_LEVEL", "debug")

	cfg := Load()

	if cfg.LogLevel != "debug" {
		t.Fatalf("expected log level 'debug', got %q", cfg.LogLevel)
	}
}
