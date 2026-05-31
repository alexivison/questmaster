package agent

// Config is the resolved questmaster agent configuration.
type Config struct {
	Agents map[string]AgentConfig `toml:"agents"`
	Roles  RolesConfig            `toml:"roles"`
}

// AgentConfig describes one configured agent provider.
type AgentConfig struct {
	CLI string `toml:"cli"`
}

// RolesConfig maps abstract roles to concrete agents.
type RolesConfig struct {
	Primary *RoleConfig `toml:"primary"`
}

// RoleConfig configures a single role binding.
type RoleConfig struct {
	Agent  string `toml:"agent"`
	Window int    `toml:"window"`
}

// ConfigOverrides are per-session role overrides.
type ConfigOverrides struct {
	Primary string
}

// DefaultConfig returns the built-in Claude primary layout.
func DefaultConfig() *Config {
	return &Config{
		Agents: map[string]AgentConfig{
			"claude": {CLI: "claude"},
			"codex":  {CLI: "codex"},
			"pi":     {CLI: "pi"},
			"omp":    {CLI: "omp"},
		},
		Roles: RolesConfig{
			Primary: &RoleConfig{Agent: "claude", Window: -1},
		},
	}
}

// LoadConfig returns the built-in config with optional per-session role
// overrides applied.
func LoadConfig(overrides *ConfigOverrides) (*Config, error) {
	cfg := DefaultConfig()
	applyOverrides(cfg, overrides)
	return cfg, nil
}

func applyOverrides(cfg *Config, overrides *ConfigOverrides) {
	if cfg == nil || overrides == nil {
		return
	}
	if cfg.Roles.Primary == nil {
		primary := *DefaultConfig().Roles.Primary
		cfg.Roles.Primary = &primary
	}
	if overrides.Primary != "" {
		cfg.Roles.Primary.Agent = overrides.Primary
	}
}
