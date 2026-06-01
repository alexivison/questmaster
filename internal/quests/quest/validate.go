package quest

import "fmt"

// Validate enforces the quest head schema (build-spec §4). It is the
// refuse-malformed gate: a quest that fails Validate must not be saved, and
// the error is fed back to the author (same refuse-and-re-engage shape gates
// use later). The auto-gate check *grammar* (github:checks, cmd:…, etc.) is the
// gate runner's concern (Stage 2) and is intentionally not enforced here.
func Validate(q Quest) error {
	if q.ID == "" {
		return fmt.Errorf("quest invalid: %q is required", "id")
	}
	if q.Goal == "" {
		return fmt.Errorf("quest invalid: %q is required", "goal")
	}
	if q.Budget < 0 {
		return fmt.Errorf("quest invalid: budget must not be negative (got %d)", q.Budget)
	}

	seen := make(map[string]struct{}, len(q.Gates))
	for i, g := range q.Gates {
		if g.Name == "" {
			return fmt.Errorf("quest invalid: gate[%d] is missing a name", i)
		}
		if _, dup := seen[g.Name]; dup {
			return fmt.Errorf("quest invalid: duplicate gate name %q", g.Name)
		}
		seen[g.Name] = struct{}{}

		switch g.Type {
		case GateAuto:
			if g.Check == "" {
				return fmt.Errorf("quest invalid: gate %q is type %q but has no check (auto requires a check)", g.Name, GateAuto)
			}
		case GateToggle:
			if g.Check != "" {
				return fmt.Errorf("quest invalid: gate %q is type %q but carries a check %q (toggle forbids a check)", g.Name, GateToggle, g.Check)
			}
		default:
			return fmt.Errorf("quest invalid: gate %q has unknown type %q (want %q or %q)", g.Name, g.Type, GateAuto, GateToggle)
		}

		if g.Before != "" && g.Before != BeforePR {
			return fmt.Errorf("quest invalid: gate %q has before %q (want %q or omitted)", g.Name, g.Before, BeforePR)
		}
	}
	return nil
}
