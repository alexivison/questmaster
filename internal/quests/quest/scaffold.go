package quest

// Scaffold returns a minimal, schema-valid wip quest for `qm quest new`. It is
// born wip — only the Questmaster approves it to active — and carries
// placeholder content plus a safe toggle reminding the author to replace it
// with a real auto gate via `qm quest edit`, because an auto gate is what qm's
// loop runs to verify the work and drive the agent. It deliberately does NOT
// invent a cmd: command (qm cannot know the repo's real command at `quest new`
// time; a wrong one would just pause the loop as misconfigured). title and
// summary fall back to safe placeholders so the scaffold always validates.
func Scaffold(id, title, summary, date string) *Quest {
	if title == "" {
		title = id
	}
	if summary == "" {
		summary = "TODO: one-line objective for " + id
	}
	return &Quest{
		ID:      id,
		Title:   title,
		Status:  StatusWIP,
		Summary: summary,
		Date:    date,
		Gates: []Gate{
			{Name: "replace-with-auto-gate", Type: GateToggle, Before: BeforePR},
		},
		Body: []Block{
			{Type: BlockHeading, Level: 2, Text: "Context"},
			{Type: BlockText, Text: "TODO: why this quest exists and what it changes."},
			{Type: BlockHeading, Level: 2, Text: "Approach"},
			{Type: BlockText, Text: "TODO: the plan, in order."},
			{Type: BlockHeading, Level: 2, Text: "Definition of done"},
			{Type: BlockText, Text: `Replace the placeholder gate with at least one real "auto" gate so qm's loop can verify the work and drive the agent after each turn. After confirming the command exists in this repo (Makefile / package.json / CI), add a gate like:`},
			{Type: BlockCode, Lang: "json", Text: `{"name": "tests", "type": "auto", "check": "cmd:go test ./...", "before": "pr"}`},
			{Type: BlockText, Text: "Keep toggle gates only for criteria qm cannot check (for example, a design review)."},
		},
	}
}
