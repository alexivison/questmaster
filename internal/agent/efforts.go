package agent

import (
	"fmt"
	"strings"
)

// ValidateReasoningEffort rejects an effort only when the harness reported a
// list for the selected model. Empty data means the harness is authoritative.
func ValidateReasoningEffort(provider, model, effort string, supported []string) error {
	if effort == "" || len(supported) == 0 {
		return nil
	}
	if provider == "opencode" && effort == "off" {
		effort = "none"
	}
	for _, level := range supported {
		if level == effort {
			return nil
		}
	}
	return fmt.Errorf("invalid --reasoning-effort %q for %s model %q (supported: %s)", effort, provider, model, strings.Join(supported, ", "))
}
