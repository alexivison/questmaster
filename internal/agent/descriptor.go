package agent

// providerDef ties an agent's static Spec to its constructor and optional
// default model. providerDefs is the single source of truth from which the
// constructor map, the default config, and the master harness-guide order are
// all derived, so a new built-in harness is declared in exactly one place
// rather than threaded through several parallel lists.
type providerDef struct {
	spec  Spec
	model string // optional default model baked into DefaultConfig
	new   func(AgentConfig) Agent
}

func (d providerDef) defaultConfig() AgentConfig {
	return AgentConfig{CLI: d.spec.DefaultCLI, Model: d.model}
}

// providerDefs lists the built-in harnesses in master harness-guide order.
// The stub provider is intentionally absent: it is constructable (for the
// reference adapter and tests) but is not a default-config agent and carries
// no harness-guide blurb.
var providerDefs = []providerDef{
	{spec: claudeSpec, new: func(c AgentConfig) Agent { return NewClaude(c) }},
	{spec: codexSpec, new: func(c AgentConfig) Agent { return NewCodex(c) }},
	{spec: openCodeSpec, model: defaultOpenCodeModel, new: func(c AgentConfig) Agent { return NewOpenCode(c) }},
	{spec: piSpec, new: func(c AgentConfig) Agent { return NewPi(c) }},
}

// specsByName indexes the built-in specs for capability lookups by the agent
// name recorded in a session manifest. Unknown names resolve to the zero Spec
// (StateNative, generic filter), which is the safe default for callers.
var specsByName = buildSpecsByName()

func buildSpecsByName() map[string]Spec {
	m := make(map[string]Spec, len(providerDefs))
	for _, d := range providerDefs {
		m[d.spec.Name] = d.spec
	}
	return m
}

// StateModeOf reports how the named agent reports activity/state. Unknown
// agents are treated as StateNative.
func StateModeOf(name string) StateMode {
	return specsByName[name].State
}

// UsesSidecarState reports whether the named agent emits the activity-sidecar
// event stream (Pi) and shares the rich read path.
func UsesSidecarState(name string) bool {
	return StateModeOf(name) == StateSidecar
}

// UsesHookActivityState reports whether the named agent's activity state is
// driven by a hook/sidecar/plugin event stream that callers consume (Pi,
// OpenCode) rather than by reading the pane directly.
func UsesHookActivityState(name string) bool {
	return StateModeOf(name) != StateNative
}

// UsesCodexFilter reports whether the named agent's pane should be read with
// the Codex-specific line filter.
func UsesCodexFilter(name string) bool {
	return specsByName[name].Filter == filterCodex
}
