package agent

// Config is the resolved questmaster agent configuration.
type Config struct {
	Agents map[string]AgentConfig `toml:"agents"`
	Roles  RolesConfig            `toml:"roles"`
}

// AgentConfig describes one configured agent provider.
type AgentConfig struct {
	CLI           string `toml:"cli"`
	Model         string `toml:"model"`
	OpenCodeAgent string `toml:"opencode_agent"`
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

// DefaultConfig returns the built-in Claude primary layout. The agent set is
// derived from providerDefs so a new built-in harness is picked up here
// automatically.
func DefaultConfig() *Config {
	agents := make(map[string]AgentConfig, len(providerDefs))
	for _, d := range providerDefs {
		agents[d.spec.Name] = d.defaultConfig()
	}
	return &Config{
		Agents: agents,
		Roles: RolesConfig{
			Primary: &RoleConfig{Agent: "claude", Window: -1},
		},
	}
}

// defaultConfigAgents is the memoized built-in agent map, derived once from
// providerDefs. Use it for read-only lookups so the fallback path does not
// rebuild the whole DefaultConfig on every call.
var defaultConfigAgents = buildDefaultConfigAgents()

func buildDefaultConfigAgents() map[string]AgentConfig {
	agents := make(map[string]AgentConfig, len(providerDefs))
	for _, d := range providerDefs {
		agents[d.spec.Name] = d.defaultConfig()
	}
	return agents
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
