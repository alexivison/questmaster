package config

import "os"

// Config holds centralized configuration for party-cli.
type Config struct {
	RepoRoot string
	LogLevel string
}

// Load reads configuration from environment variables.
// PARTY_REPO_ROOT is required — shell launchers must set it explicitly
// (see session/party-master.sh:50-55 for the precedent).
func Load() Config {
	return Config{
		RepoRoot: os.Getenv("PARTY_REPO_ROOT"),
		LogLevel: envOr("PARTY_LOG_LEVEL", "info"),
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
