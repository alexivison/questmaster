package quest

// Scaffold returns a minimal, schema-valid wip quest for `qm quest new`. It is
// born wip — only the Questmaster approves it to active — and carries
// placeholder content plus a starter gate set the author elaborates via
// `qm quest edit`. title and summary fall back to safe placeholders so the
// scaffold always validates.
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
			{Name: "tests", Type: GateAuto, Check: "cmd:make test"},
			{Name: "review", Type: GateToggle, Before: BeforePR},
		},
		Body: []Block{
			{Type: BlockHeading, Level: 2, Text: "Context"},
			{Type: BlockText, Text: "TODO: why this quest exists and what it changes."},
			{Type: BlockHeading, Level: 2, Text: "Approach"},
			{Type: BlockText, Text: "TODO: the plan, in order."},
		},
	}
}
