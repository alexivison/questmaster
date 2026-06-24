package quest

import "fmt"

// ToggleGate flips one human-owned toggle gate and returns its new checked state.
func ToggleGate(q *Quest, gateName string) (bool, error) {
	if q == nil {
		return false, fmt.Errorf("quest is missing")
	}
	if gateName == "" {
		return false, fmt.Errorf("gate name is required")
	}
	for i := range q.Gates {
		if q.Gates[i].Name != gateName {
			continue
		}
		if q.Gates[i].Type != GateToggle {
			return false, fmt.Errorf("gate %q is %q; only toggle gates can be checked", gateName, q.Gates[i].Type)
		}
		q.Gates[i].Checked = !q.Gates[i].Checked
		return q.Gates[i].Checked, nil
	}
	return false, fmt.Errorf("gate %q not found", gateName)
}
