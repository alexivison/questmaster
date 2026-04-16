package agent

import (
	"fmt"
	"sort"
)

// Registry resolves configured role bindings to built-in agent providers.
type Registry struct {
	agents   map[string]Agent
	bindings map[Role]*RoleBinding
}

var providerConstructors = map[string]func(AgentConfig) Agent{
	"claude": func(cfg AgentConfig) Agent { return NewClaude(cfg) },
	"codex":  func(cfg AgentConfig) Agent { return NewCodex(cfg) },
	"stub":   func(cfg AgentConfig) Agent { return NewStub(cfg) },
}

// NewRegistry builds a registry from a loaded config.
func NewRegistry(cfg *Config) (*Registry, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}

	r := &Registry{
		agents:   make(map[string]Agent, len(cfg.Agents)),
		bindings: make(map[Role]*RoleBinding, 2),
	}

	for name, agentCfg := range cfg.Agents {
		constructor, ok := providerConstructors[name]
		if !ok {
			return nil, fmt.Errorf("unknown agent %q", name)
		}
		r.agents[name] = constructor(agentCfg)
	}

	if cfg.Roles.Primary == nil || cfg.Roles.Primary.Agent == "" {
		return nil, fmt.Errorf("primary role is not configured")
	}
	if err := r.bindRole(RolePrimary, cfg.Roles.Primary); err != nil {
		return nil, err
	}
	if cfg.Roles.Companion != nil {
		if err := r.bindRole(RoleCompanion, cfg.Roles.Companion); err != nil {
			return nil, err
		}
	}
	if primary, ok := r.bindings[RolePrimary]; ok {
		if companion, ok := r.bindings[RoleCompanion]; ok && primary.Agent.Name() == companion.Agent.Name() {
			return nil, fmt.Errorf("primary and companion cannot use the same agent %q", primary.Agent.Name())
		}
	}

	return r, nil
}

func (r *Registry) bindRole(role Role, cfg *RoleConfig) error {
	if cfg == nil || cfg.Agent == "" {
		return nil
	}
	agent, ok := r.agents[cfg.Agent]
	if !ok {
		return fmt.Errorf("role %s references unknown agent %q", role, cfg.Agent)
	}
	r.bindings[role] = &RoleBinding{
		Role:     role,
		Agent:    agent,
		PaneRole: string(role),
		Window:   cfg.Window,
	}
	return nil
}

// Get returns a configured agent provider by name.
func (r *Registry) Get(name string) (Agent, error) {
	agent, ok := r.agents[name]
	if !ok {
		return nil, fmt.Errorf("agent %q is not configured", name)
	}
	return agent, nil
}

// ForRole returns the binding for a configured role.
func (r *Registry) ForRole(role Role) (*RoleBinding, error) {
	binding, ok := r.bindings[role]
	if !ok {
		return nil, fmt.Errorf("role %s is not configured", role)
	}
	return binding, nil
}

// Bindings returns configured role bindings in primary-first order.
func (r *Registry) Bindings() []*RoleBinding {
	out := make([]*RoleBinding, 0, 2)
	for _, role := range []Role{RolePrimary, RoleCompanion} {
		if binding, ok := r.bindings[role]; ok {
			out = append(out, binding)
		}
	}
	return out
}

// HasRole reports whether the given role is configured.
func (r *Registry) HasRole(role Role) bool {
	_, ok := r.bindings[role]
	return ok
}

// Names returns configured agent definition names in sorted order.
func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.agents))
	for name := range r.agents {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Resolve returns an agent by name, preferring the configured registry and
// falling back to built-in providers when the current config does not bind it.
func Resolve(name string, registry *Registry) (Agent, error) {
	if registry != nil {
		if agent, err := registry.Get(name); err == nil {
			return agent, nil
		}
	}

	constructor, ok := providerConstructors[name]
	if !ok {
		return nil, fmt.Errorf("agent %q is not configured", name)
	}
	cfg := AgentConfig{}
	if builtin, ok := DefaultConfig().Agents[name]; ok {
		cfg = builtin
	}
	return constructor(cfg), nil
}
