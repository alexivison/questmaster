package agent

import "strings"

// ModelPolicy is a harness's declared model story: the role default models it
// launches with, and where a dynamic list of selectable models comes from.
//
// It exists so that adding a model — or a whole new model family — never means
// editing Questmaster. The role defaults are the only model ids baked into the
// binary; everything offered as a choice is resolved at runtime from the
// catalog sources below (and, for harnesses that can enumerate their own
// models, from the harness itself).
type ModelPolicy struct {
	// Worker is the default model for worker and standalone sessions.
	Worker string
	// Master is the default model for master sessions.
	Master string
	// Sources map catalog providers onto the model strings this harness
	// accepts. Order is presentation order.
	Sources []ModelSource
}

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

// DefaultModelFor returns the model a *freshly-constructed default* instance
// of the named agent launches with for a role when no override is given. It
// reflects only the harness's static ModelPolicy — it cannot see instance-level
// state a specific Agent value's BuildCmd might also consult (OpenCode's
// configured-model override for standalone). Prefer Agent.DefaultModel when an
// actual instance is available (e.g. via agent.Resolve); this free function
// exists for callers that only have a bare agent name, such as
// `questmaster models` and the wire-contract fallback in modelsuggest.
func DefaultModelFor(name string, role SessionRole) string {
	policy := ModelPolicyOf(name)
	return resolveModel(CmdOpts{Role: role}, policy.Worker, policy.Master)
}

// RoleDefaultsKey collapses a session role to the two buckets the persisted
// role-defaults store keys on: everything but master shares the worker tier,
// mirroring resolveModel's own master-vs-everything-else convention.
func RoleDefaultsKey(role SessionRole) string {
	if role == RoleMaster {
		return "master"
	}
	return "worker"
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
