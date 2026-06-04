// Package quest is the quest file format: the load-bearing types plus parsing
// and schema validation of the quest document. A quest is JSON — the single
// source of truth — embedded in a self-contained HTML file inside a
// <script type="application/json" id="quest"> block. The terminal reads the
// JSON and renders a detail pane (render.go); a build step turns the same JSON
// into the browser HTML (build.go). Two renderers, one parsed model.
//
// Stage 1 parses, validates, renders, and displays gates; it does not execute
// them (the gate runner is Stage 2). Status is human-owned and never set by an
// executing agent.
package quest

// Status is the authored, human-owned lifecycle state of a quest. A quest is
// born wip, approved to active by the Questmaster, and marked done once its
// gates hold. The agent never sets this.
type Status string

const (
	// StatusWIP is a draft awaiting the Questmaster's review.
	StatusWIP Status = "wip"
	// StatusActive is posted to the board and attachable to a session.
	StatusActive Status = "active"
	// StatusDone is a turned-in quest the Questmaster has accepted.
	StatusDone Status = "done"
)

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

// Block type discriminators for the body[] array.
const (
	BlockHeading = "heading"
	BlockText    = "text"
	BlockList    = "list"
	BlockCode    = "code"
	BlockRich    = "rich"
)

// Gate is a single done-criterion. Check is required iff Type == auto and must
// be empty for toggle. Before names the transition the gate guards ("" guards
// done; "pr" is a barrier before PR creation). The check grammar
// (cmd:<shell>, github:checks, …) is authored and displayed this stage, not
// executed.
type Gate struct {
	Name   string   `json:"name"`
	Type   GateType `json:"type"`
	Check  string   `json:"check,omitempty"`
	Before string   `json:"before,omitempty"`
	// Checked is the human-authored met-state of a toggle gate ([x] vs [ ]).
	// It is authored, so it lives in the JSON. Auto gates never carry it —
	// their results are observed, not authored, and live in the runtime sidecar.
	Checked bool `json:"checked,omitempty"`
}

// Block is one ordered body block. Its meaning is discriminated by Type; the
// fields a Type uses are documented per kind. Array order is document order,
// so structure is preserved for free. A single flat shape keeps the model
// simple and lets both renderers dispatch on Type. Unknown types are not an
// error — they degrade to Fallback at render time (forward compatibility).
//
//   - heading: Level, Text
//   - text:    Text
//   - list:    Ordered, Items
//   - code:    Lang, Text
//   - rich:    Format, Fallback, Content
//
// ID is an optional stable handle on any block, for future referencing.
type Block struct {
	Type string `json:"type"`
	ID   string `json:"id,omitempty"`

	// heading
	Level int `json:"level,omitempty"`

	// heading, text, code
	Text string `json:"text,omitempty"`

	// list
	Ordered bool     `json:"ordered,omitempty"`
	Items   []string `json:"items,omitempty"`

	// code
	Lang string `json:"lang,omitempty"`

	// rich
	Format   string `json:"format,omitempty"`
	Fallback string `json:"fallback,omitempty"`
	Content  string `json:"content,omitempty"`
}

// RelatedLink is a related ticket / PR / doc: a typed, titled, optionally
// linked reference. The HTML build renders it as an anchor; the terminal shows
// the title (and, later, the app can open the URL). For backward compatibility
// a bare JSON string decodes into a RelatedLink with just its Title set (see
// UnmarshalJSON in parse.go).
type RelatedLink struct {
	Type  string `json:"type,omitempty"`
	Title string `json:"title"`
	URL   string `json:"url,omitempty"`
}

// Quest is the parsed canonical JSON of a quest: docs-style frontmatter, the
// gates that are the definition of done, and the ordered body blocks. It is
// the single source of truth — the HTML body is generated from it and never
// parsed back.
type Quest struct {
	ID      string        `json:"id"`
	Title   string        `json:"title"`
	Status  Status        `json:"status"`
	Summary string        `json:"summary"`
	Date    string        `json:"date,omitempty"`
	Agent   string        `json:"agent,omitempty"`
	Project string        `json:"project,omitempty"`
	Related []RelatedLink `json:"related,omitempty"`

	Gates []Gate  `json:"gates,omitempty"`
	Body  []Block `json:"body,omitempty"`
}
