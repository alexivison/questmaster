// Package quest is the quest file format: the load-bearing types plus parsing
// and schema validation of the HTML quest document (visible JSON head + rich
// body). Stage 1 parses, validates, and displays gates; it does not execute
// them (the gate runner is Stage 2).
package quest

// GateType is the kind of a single done-criterion.
type GateType string

const (
	// GateAuto is a runnable check measured externally by the harness.
	GateAuto GateType = "auto"
	// GateToggle is a human checkbox; the honest home for anything unverifiable.
	GateToggle GateType = "toggle"
)

// BeforePR is the only non-empty gate position in Stage 1: a barrier the loop
// will not cross until the gate passes, holding PR creation.
const BeforePR = "pr"

// Gate is a single done-criterion. Check is required iff Type == auto and must
// be empty for toggle. Before names the transition the gate guards ("" guards
// done; "pr" is a barrier before PR creation).
type Gate struct {
	Name   string   `json:"name"`
	Type   GateType `json:"type"`
	Check  string   `json:"check,omitempty"`
	Before string   `json:"before,omitempty"`
}

// Quest is the parsed canonical JSON head of a quest file (build-spec §4).
// Forward-compat fields (PrimaryRef, Budget) are present now but may be unset
// in Stage 1.
type Quest struct {
	ID         string   `json:"id"`
	Goal       string   `json:"goal"`
	Gates      []Gate   `json:"gates,omitempty"`
	Next       []string `json:"next,omitempty"`
	Context    []string `json:"context,omitempty"` // refs: "linear:ENG-142", ...
	Worktree   string   `json:"worktree,omitempty"`
	PrimaryRef string   `json:"primary_ref,omitempty"`
	Budget     int      `json:"budget,omitempty"`
}

// Document is the whole quest file: the validated head plus the raw HTML
// document, which is rendered as-is (the browser view) and never parsed back
// into the Quest. One file, two parts.
type Document struct {
	Head Quest
	Body []byte // the raw HTML document, byte-preserved for round-trip + render
}
