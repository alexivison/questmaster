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

// providerConstructors is derived from providerDefs (the single source of
// truth) plus the constructor-only stub provider.
var providerConstructors = buildProviderConstructors()

func buildProviderConstructors() map[string]func(AgentConfig) Agent {
	m := make(map[string]func(AgentConfig) Agent, len(providerDefs)+1)
	for _, d := range providerDefs {
		m[d.spec.Name] = d.new
	}
	m["stub"] = func(cfg AgentConfig) Agent { return NewStub(cfg) }
	return m
}

// NewRegistry builds a registry from a loaded config.
func NewRegistry(cfg *Config) (*Registry, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}

	r := &Registry{
		agents:   make(map[string]Agent, len(cfg.Agents)),
		bindings: make(map[Role]*RoleBinding, 1),
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
		Role:  role,
		Agent: agent,
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
	out := make([]*RoleBinding, 0, 1)
	for _, role := range []Role{RolePrimary} {
		if binding, ok := r.bindings[role]; ok {
			out = append(out, binding)
		}
	}
	return out
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
	if builtin, ok := defaultConfigAgents[name]; ok {
		cfg = builtin
	}
	return constructor(cfg), nil
}
