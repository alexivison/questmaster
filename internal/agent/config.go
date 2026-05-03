package agent

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

// Config is the parsed user-global party-cli configuration.
type Config struct {
	Agents   map[string]AgentConfig `toml:"agents"`
	Roles    RolesConfig            `toml:"roles"`
	Evidence EvidenceConfig         `toml:"evidence"`
}

// AgentConfig describes one configured agent provider.
type AgentConfig struct {
	CLI string `toml:"cli"`
}

// RolesConfig maps abstract roles to concrete agents.
type RolesConfig struct {
	Primary   *RoleConfig `toml:"primary"`
	Companion *RoleConfig `toml:"companion"`
}

// RoleConfig configures a single role binding.
type RoleConfig struct {
	Agent  string `toml:"agent"`
	Window int    `toml:"window"`
}

// EvidenceConfig controls PR-gate evidence requirements.
type EvidenceConfig struct {
	Required []string `toml:"required"`
}

// ConfigOverrides are per-session role overrides.
type ConfigOverrides struct {
	Primary     string
	Companion   string
	NoCompanion bool
}

// DefaultConfig returns the built-in Claude primary + Codex companion layout.
func DefaultConfig() *Config {
	return &Config{
		Agents: map[string]AgentConfig{
			"claude": {CLI: "claude"},
			"codex":  {CLI: "codex"},
			"pi":     {CLI: "pi"},
		},
		Roles: RolesConfig{
			Primary:   &RoleConfig{Agent: "claude", Window: -1},
			Companion: &RoleConfig{Agent: "codex", Window: 0},
		},
	}
}

// UserConfigPath returns the user-global config path for party-cli.
func UserConfigPath() (string, error) {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "party-cli", "config.toml"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve user home dir: %w", err)
	}
	return filepath.Join(home, ".config", "party-cli", "config.toml"), nil
}

// LoadConfig reads the user-global config file, falling back to defaults when
// the file does not exist, then applies optional per-session role overrides.
func LoadConfig(overrides *ConfigOverrides) (*Config, error) {
	path, err := UserConfigPath()
	if err != nil {
		return nil, err
	}

	var cfg *Config
	info, err := os.Stat(path)
	switch {
	case os.IsNotExist(err):
		cfg = DefaultConfig()
	case err != nil:
		return nil, fmt.Errorf("stat %s: %w", path, err)
	case info.IsDir():
		return nil, fmt.Errorf("config path %s is a directory", path)
	default:
		cfg, err = loadConfigFile(path)
		if err != nil {
			return nil, err
		}
	}

	applyOverrides(cfg, overrides)
	hydrateReferencedAgents(cfg)
	return cfg, nil
}

func loadConfigFile(path string) (*Config, error) {
	var parsed Config
	meta, err := toml.DecodeFile(path, &parsed)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}

	cfg := &Config{
		Agents:   parsed.Agents,
		Evidence: parsed.Evidence,
	}
	if cfg.Agents == nil {
		cfg.Agents = make(map[string]AgentConfig)
	}

	defaults := DefaultConfig()
	hasRoles := meta.IsDefined("roles")
	hasPrimary := meta.IsDefined("roles", "primary")
	hasCompanion := meta.IsDefined("roles", "companion")

	if !hasRoles {
		cfg.Roles.Primary = cloneRoleConfig(defaults.Roles.Primary)
		cfg.Roles.Companion = cloneRoleConfig(defaults.Roles.Companion)
	} else {
		if hasPrimary {
			cfg.Roles.Primary = mergeRoleConfig(
				parsed.Roles.Primary,
				defaults.Roles.Primary,
				meta.IsDefined("roles", "primary", "agent"),
				meta.IsDefined("roles", "primary", "window"),
			)
		} else {
			cfg.Roles.Primary = cloneRoleConfig(defaults.Roles.Primary)
		}
		if hasCompanion {
			cfg.Roles.Companion = mergeRoleConfig(
				parsed.Roles.Companion,
				defaults.Roles.Companion,
				meta.IsDefined("roles", "companion", "agent"),
				meta.IsDefined("roles", "companion", "window"),
			)
		} else {
			cfg.Roles.Companion = nil
		}
	}

	return cfg, nil
}

func applyOverrides(cfg *Config, overrides *ConfigOverrides) {
	if cfg == nil || overrides == nil {
		return
	}
	if cfg.Roles.Primary == nil {
		cfg.Roles.Primary = cloneRoleConfig(DefaultConfig().Roles.Primary)
	}
	if overrides.Primary != "" {
		cfg.Roles.Primary.Agent = overrides.Primary
	}
	if overrides.NoCompanion {
		cfg.Roles.Companion = nil
		return
	}
	if overrides.Companion != "" {
		if cfg.Roles.Companion == nil {
			cfg.Roles.Companion = &RoleConfig{Window: 0}
		}
		cfg.Roles.Companion.Agent = overrides.Companion
	}
}

func hydrateReferencedAgents(cfg *Config) {
	if cfg.Agents == nil {
		cfg.Agents = make(map[string]AgentConfig)
	}

	defaults := DefaultConfig().Agents
	for name, agentCfg := range cfg.Agents {
		if agentCfg.CLI == "" {
			if builtin, ok := defaults[name]; ok {
				agentCfg.CLI = builtin.CLI
				cfg.Agents[name] = agentCfg
			}
		}
	}

	for _, roleCfg := range []*RoleConfig{cfg.Roles.Primary, cfg.Roles.Companion} {
		if roleCfg == nil || roleCfg.Agent == "" {
			continue
		}
		if _, ok := cfg.Agents[roleCfg.Agent]; ok {
			continue
		}
		if builtin, ok := defaults[roleCfg.Agent]; ok {
			cfg.Agents[roleCfg.Agent] = builtin
		}
	}
}

func cloneRoleConfig(cfg *RoleConfig) *RoleConfig {
	if cfg == nil {
		return nil
	}
	out := *cfg
	return &out
}

func mergeRoleConfig(parsed, base *RoleConfig, hasAgent, hasWindow bool) *RoleConfig {
	if parsed == nil && base == nil {
		return nil
	}

	merged := &RoleConfig{}
	if hasAgent {
		merged.Agent = parsed.Agent
	} else if base != nil {
		merged.Agent = base.Agent
	}

	if hasWindow {
		merged.Window = parsed.Window
	} else if base != nil {
		merged.Window = base.Window
	}

	return merged
}
