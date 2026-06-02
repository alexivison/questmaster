package quest

import "fmt"

// validStatuses is the closed set of human-owned lifecycle states.
var validStatuses = map[Status]struct{}{
	StatusWIP:    {},
	StatusActive: {},
	StatusDone:   {},
}

// validRichFormats is the closed set of rich-block payload formats. The
// terminal shows the fallback for all of them; the HTML build injects content
// per format.
var validRichFormats = map[string]struct{}{
	"html":    {},
	"table":   {},
	"mermaid": {},
	"chart":   {},
	"image":   {},
}

// Validate enforces the quest schema (quest-format.md). It is the
// refuse-malformed gate: a quest that fails Validate must not be saved, and the
// error is fed back to the author (the refuse-and-re-engage loop). Errors are
// single-line and specific so an authoring session can self-correct. Malformed
// JSON is caught earlier, by Parse.
func Validate(q *Quest) error {
	if q == nil {
		return fmt.Errorf("quest invalid: nil quest")
	}
	if q.ID == "" {
		return fmt.Errorf("quest invalid: %q is required", "id")
	}
	if q.Title == "" {
		return fmt.Errorf("quest invalid: %q is required", "title")
	}
	if q.Summary == "" {
		return fmt.Errorf("quest invalid: %q is required", "summary")
	}
	if q.Status == "" {
		return fmt.Errorf("quest invalid: %q is required", "status")
	}
	if _, ok := validStatuses[q.Status]; !ok {
		return fmt.Errorf("quest invalid: status %q is not one of wip, active, done", q.Status)
	}

	if err := validateGates(q.Gates); err != nil {
		return err
	}
	for i, r := range q.Related {
		if r.Title == "" {
			return fmt.Errorf("quest invalid: related[%d] is missing a title", i)
		}
	}
	return validateBody(q.Body)
}

func validateGates(gates []Gate) error {
	seen := make(map[string]struct{}, len(gates))
	for i, g := range gates {
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

func validateBody(body []Block) error {
	for i, b := range body {
		if b.Type == "" {
			return fmt.Errorf("quest invalid: body[%d] is missing a type", i)
		}
		switch b.Type {
		case BlockHeading:
			if b.Text == "" {
				return fmt.Errorf("quest invalid: body[%d] heading has no text", i)
			}
			if b.Level < 1 || b.Level > 6 {
				return fmt.Errorf("quest invalid: body[%d] heading level %d out of range (want 1-6)", i, b.Level)
			}
		case BlockText:
			if b.Text == "" {
				return fmt.Errorf("quest invalid: body[%d] text block has no text", i)
			}
		case BlockList:
			if len(b.Items) == 0 {
				return fmt.Errorf("quest invalid: body[%d] list has no items", i)
			}
		case BlockCode:
			if b.Text == "" {
				return fmt.Errorf("quest invalid: body[%d] code block has no text", i)
			}
		case BlockRich:
			if b.Format == "" {
				return fmt.Errorf("quest invalid: body[%d] rich block is missing a format", i)
			}
			if _, ok := validRichFormats[b.Format]; !ok {
				return fmt.Errorf("quest invalid: body[%d] rich block format %q is not one of html, table, mermaid, chart, image", i, b.Format)
			}
			if b.Fallback == "" {
				return fmt.Errorf("quest invalid: body[%d] rich block is missing a fallback", i)
			}
		default:
			// Unknown block types are not rejected: an old binary degrades them
			// to their fallback at render time rather than refusing the quest.
		}
	}
	return nil
}
