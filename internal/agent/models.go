package agent

import "strings"

// ModelPolicy is a harness's declared model story: where a dynamic list of
// selectable models comes from. Questmaster's explicit role default is stored
// in Settings; choices are resolved at runtime from its native listing and
// optional catalog sources.
type ModelPolicy struct {
	// Native lists models through the harness itself. Without catalog sources,
	// suggestions are limited to its currently available models.
	Native ModelListSource
	// Sources map catalog providers onto the model strings this harness
	// accepts. Order is presentation order.
	Sources []ModelSource
}

// ModelListSource identifies a harness-owned model listing command.
type ModelListSource string

const ModelListPi ModelListSource = "pi-list-models"

// EffortSource identifies a harness-owned input used to resolve reasoning-
// effort choices and the model they apply to. modelsuggest reads it at runtime.
type EffortSource string

const (
	EffortSourceNone        EffortSource = ""
	EffortSourceCodexCache  EffortSource = "codex-cache"
	EffortSourceClaudeHelp  EffortSource = "claude-help"
	EffortSourcePiHelp      EffortSource = "pi-help"
	EffortSourceCodexConfig EffortSource = "codex-config"
)

// ModelSource maps one models.dev provider onto a harness's model vocabulary.
//
// Claude and Codex take bare model ids. Claude also accepts family aliases
// such as "opus". Pi lists its provider-qualified ids through its own CLI.
type ModelSource struct {
	// Catalog is the models.dev provider id (e.g. "anthropic", "openai").
	Catalog string
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
