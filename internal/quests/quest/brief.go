package quest

import (
	"fmt"
	"strings"
)

// WorkingClause is the per-session briefing for a session attached to a quest:
// the goal, the gates as the definition of done, the plan, and the working
// rules. qm seeds it as the opening prompt at spawn and injects it on attach.
// It hands the agent the parsed quest and the one hard rule that keeps status
// human-owned: you work to the gates, you cannot mark the quest done, and you
// can re-read the current quest at any time.
func WorkingClause(q *Quest) string {
	var b strings.Builder
	fmt.Fprintf(&b, "You are working on quest %s — %s.\n\n", q.ID, q.Title)
	fmt.Fprintf(&b, "Goal: %s\n\n", q.Goal())

	b.WriteString("Definition of done (the gates):\n")
	if len(q.Gates) == 0 {
		b.WriteString("  (no gates defined)\n")
	} else {
		for _, g := range q.Gates {
			line := "  - " + g.Name + " (" + string(g.Type) + ")"
			if c := gateCheckText(g); c != "" {
				line += ": " + c
			}
			b.WriteString(line + "\n")
		}
	}
	b.WriteString("\n")

	if plan := plainBody(q); plan != "" {
		b.WriteString("Plan:\n")
		b.WriteString(plan)
		b.WriteString("\n\n")
	}

	fmt.Fprintf(&b, "Work to the gates above. You cannot mark this quest done — "+
		"only the Questmaster sets status. Re-read the current quest at any time with `qm quest view %s`.", q.ID)
	return b.String()
}

// AuthoringClause is the briefing for a master or standalone session: how to
// create and write a conformant quest through qm, where quests live, that gates
// must be real checkable criteria, to run the validator, and that the author
// cannot post (approve) or close (mark done) a quest. Injected as persistent
// identity so any master/standalone is quest-authoring-aware.
func AuthoringClause() string { return authoringClause }

const authoringClause = `Quests: you can capture a plan as a quest through qm. A quest is an HTML file ` +
	`(canonical JSON + generated body) stored under ~/.questmaster/quests, never in a repo — always go through qm, ` +
	`never write the file yourself. Author with: questmaster quest new (scaffolds a wip quest and auto-generates ` +
	`a quest-specific id; do not pass an id and never invent a slug id yourself). ` +
	`questmaster quest edit <id> (edit the JSON; it is validated and the body rebuilt on save), and ` +
	`questmaster quest validate <id> / view <id> to check and read it. Required fields: id, title, summary, status. ` +
	`Gates are the definition of done and must be real checkable criteria. An "auto" gate is verified by qm running ` +
	`a "cmd:<shell>" check, so write the REAL command this repo uses — discover it by reading the Makefile, the package.json ` +
	`scripts, or the CI config in the worktree you are in (for example, after verifying it exists, "cmd:go test ./..." ` +
	`or "cmd:npm run typecheck"). ` +
	`Use only commands you have confirmed exist in this repo; a check that does not run to a verdict is useless. ` +
	`A "toggle" gate is a human checkbox for anything a command cannot verify, and carries no check. PR approved, ` +
	`CI green, and PR merged are toggle/human gates for now, not auto gates, until qm has real GitHub gate support. If the validator ` +
	`refuses the quest, fix the reported error and try again. You draft and elaborate quests; you cannot post ` +
	`(approve) or close (mark done) them — only the Questmaster sets status.`

// plainBody flattens the ordered body blocks to plain text for the working
// briefing: headings, paragraphs, list items, code, and rich fallbacks.
func plainBody(q *Quest) string {
	var lines []string
	for _, b := range q.Body {
		switch b.Type {
		case BlockHeading:
			lines = append(lines, "", b.Text)
		case BlockText:
			lines = append(lines, b.Text)
		case BlockList:
			for i, it := range b.Items {
				marker := "- "
				if b.Ordered {
					marker = fmt.Sprintf("%d. ", i+1)
				}
				lines = append(lines, marker+it)
			}
		case BlockCode:
			lines = append(lines, b.Text)
		case BlockRich:
			lines = append(lines, "["+b.Format+"] "+b.Fallback)
		default:
			if b.Fallback != "" {
				lines = append(lines, b.Fallback)
			}
		}
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}
