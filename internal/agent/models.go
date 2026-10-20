package agent

import "strings"

// ModelPolicy is a harness's declared model story: where a dynamic list of
// selectable models comes from. Questmaster's explicit role default is stored
// in Settings; choices are resolved at runtime from the catalog sources below
// (and, for harnesses that can enumerate their own models, from the harness).
type ModelPolicy struct {
	// Sources map catalog providers onto the model strings this harness
	// accepts. Order is presentation order.
	Sources []ModelSource
}

// EffortSource identifies a harness-owned input used to resolve reasoning-
// effort choices and the model they apply to. modelsuggest reads it at runtime.
type EffortSource string

const (
	EffortSourceNone           EffortSource = ""
	EffortSourceCodexCache     EffortSource = "codex-cache"
	EffortSourceClaudeHelp     EffortSource = "claude-help"
	EffortSourcePiHelp         EffortSource = "pi-help"
	EffortSourceOpenCodeModels EffortSource = "opencode-models"
	EffortSourceCodexConfig    EffortSource = "codex-config"
	EffortSourceOpenCodeConfig EffortSource = "opencode-config"
)

// ModelSource maps one models.dev provider onto a harness's model vocabulary.
//
// Harnesses disagree about how a model is named: Claude takes bare ids
// ("claude-opus-5") or family aliases ("opus"), Codex takes bare OpenAI ids
// ("gpt-5.6-terra"), and OpenCode and Pi take provider-qualified ids with
// their own provider naming ("openai/gpt-5.6-terra",
// "openai-codex/gpt-5.6-terra"). Prefix bridges that gap without a per-model
// mapping table.
type ModelSource struct {
	// Catalog is the models.dev provider id (e.g. "anthropic", "openai").
	Catalog string
	// Prefix is prepended to every catalog model id for this harness.
	Prefix string
	// Efforts names an effort source used by a provider-qualified model mapping.
	Efforts EffortSource
	// Aliases additionally offers family-derived aliases (the "claude-opus"
	// family becomes "opus"). Aliases track the latest model in their family,
	// so they are the preferred choice where a harness supports them.
	Aliases bool
}

// ModelPolicyOf returns the named agent's model policy. Unknown agents resolve
// to the zero policy, which means "no declared defaults, no suggestions" —
// callers still accept any model string the user types.
func ModelPolicyOf(name string) ModelPolicy {
	return specsByName[name].Models
}

// RoleDefaultsKey maps a session role to its bucket in the persisted
// role-defaults store.
func RoleDefaultsKey(role SessionRole) string {
	switch role {
	case RoleMaster:
		return "master"
	case RoleWorker:
		return "worker"
	default:
		return "master"
	}
}

// FamilyAlias reduces a models.dev family to the short alias a harness
// accepts, by dropping the vendor-prefixed head of the family name:
// "claude-opus" becomes "opus". Families with no separator have no alias.
func FamilyAlias(family string) string {
	_, alias, ok := strings.Cut(strings.TrimSpace(family), "-")
	if !ok {
		return ""
	}
	return alias
}
