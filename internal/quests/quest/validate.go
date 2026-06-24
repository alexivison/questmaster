package quest

import (
	"fmt"
	"strings"
)

// validStatuses is the closed set of human-owned lifecycle states.
var validStatuses = map[Status]struct{}{
	StatusWIP:    {},
	StatusActive: {},
	StatusDone:   {},
}

var validCommentStatuses = map[CommentStatus]struct{}{
	CommentOpen:     {},
	CommentResolved: {},
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
	if err := validateRelated(q.Related); err != nil {
		return err
	}
	if err := validateAttachments(q.Attachments); err != nil {
		return err
	}
	if err := validateBody(q.Body); err != nil {
		return err
	}
	return validateComments(q)
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

		if g.Type == GateAuto && g.Checked {
			return fmt.Errorf("quest invalid: gate %q is type %q but carries checked (auto results are observed, not authored)", g.Name, GateAuto)
		}

		if g.Before != "" && g.Before != BeforePR {
			return fmt.Errorf("quest invalid: gate %q has before %q (want %q or omitted)", g.Name, g.Before, BeforePR)
		}
	}
	return nil
}

func validateRelated(related []RelatedLink) error {
	seen := map[string]struct{}{}
	for i, r := range related {
		if r.Title == "" {
			return fmt.Errorf("quest invalid: related[%d] is missing a title", i)
		}
		if r.ID == "" {
			continue
		}
		if _, dup := seen[r.ID]; dup {
			return fmt.Errorf("quest invalid: duplicate related id %q", r.ID)
		}
		seen[r.ID] = struct{}{}
	}
	return nil
}

func validateAttachments(attachments []AttachmentRef) error {
	seen := map[string]struct{}{}
	for i, ref := range attachments {
		if strings.TrimSpace(ref.ItemID) == "" {
			return fmt.Errorf("quest invalid: attachments[%d] is missing item_id", i)
		}
		if strings.TrimSpace(ref.Type) == "" {
			return fmt.Errorf("quest invalid: attachment %q is missing a type", ref.ItemID)
		}
		if strings.TrimSpace(ref.Title) == "" {
			return fmt.Errorf("quest invalid: attachment %q is missing a title", ref.ItemID)
		}
		if _, dup := seen[ref.ItemID]; dup {
			return fmt.Errorf("quest invalid: duplicate attachment item_id %q", ref.ItemID)
		}
		seen[ref.ItemID] = struct{}{}
	}
	return nil
}

func validateBody(body []Block) error {
	seen := map[string]struct{}{}
	for i, b := range body {
		if b.Type == "" {
			return fmt.Errorf("quest invalid: body[%d] is missing a type", i)
		}
		if b.ID != "" {
			if _, dup := seen[b.ID]; dup {
				return fmt.Errorf("quest invalid: duplicate body id %q", b.ID)
			}
			seen[b.ID] = struct{}{}
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

func validateComments(q *Quest) error {
	seen := map[string]struct{}{}
	for i, c := range q.Comments {
		if strings.TrimSpace(c.ID) == "" {
			return fmt.Errorf("quest invalid: comment[%d] is missing an id", i)
		}
		if _, dup := seen[c.ID]; dup {
			return fmt.Errorf("quest invalid: duplicate comment id %q", c.ID)
		}
		seen[c.ID] = struct{}{}
		if c.Status == "" {
			return fmt.Errorf("quest invalid: comment %q is missing a status", c.ID)
		}
		if _, ok := validCommentStatuses[c.Status]; !ok {
			return fmt.Errorf("quest invalid: comment %q status %q is not one of open, resolved", c.ID, c.Status)
		}
		if strings.TrimSpace(c.Body) == "" {
			return fmt.Errorf("quest invalid: comment %q is missing a body", c.ID)
		}
		if strings.TrimSpace(c.CreatedAt) == "" {
			return fmt.Errorf("quest invalid: comment %q is missing created_at", c.ID)
		}
		if err := validateCommentAnchor(q, c.Anchor); err != nil {
			return fmt.Errorf("quest invalid: comment %q %v", c.ID, err)
		}
	}
	return nil
}

// ValidateCommentAnchor checks whether an anchor currently points at a stable
// quest element. It is exported so mutation commands can fail before opening
// an editor when the requested target cannot exist.
func ValidateCommentAnchor(q *Quest, anchor CommentAnchor) error {
	if q == nil {
		return fmt.Errorf("comment anchor invalid: nil quest")
	}
	if err := validateCommentAnchor(q, anchor); err != nil {
		return fmt.Errorf("comment anchor invalid: %w", err)
	}
	return nil
}

func validateCommentAnchor(q *Quest, anchor CommentAnchor) error {
	switch anchor.Kind {
	case CommentAnchorQuest:
		if anchor.ID != "" {
			return fmt.Errorf("anchor quest must not carry an id")
		}
		if anchor.Item != nil {
			return fmt.Errorf("anchor quest must not carry an item")
		}
		return nil
	case CommentAnchorGate:
		if anchor.ID == "" {
			return fmt.Errorf("anchor gate is missing an id")
		}
		if anchor.Item != nil {
			return fmt.Errorf("anchor gate must not carry an item")
		}
		for _, g := range q.Gates {
			if g.Name == anchor.ID {
				return nil
			}
		}
		return fmt.Errorf("anchor %s does not match any gate", anchor.String())
	case CommentAnchorRelated:
		if anchor.ID == "" {
			return fmt.Errorf("anchor related is missing an id")
		}
		if anchor.Item != nil {
			return fmt.Errorf("anchor related must not carry an item")
		}
		for _, r := range q.Related {
			if r.ID == anchor.ID {
				return nil
			}
		}
		return fmt.Errorf("anchor %s does not match any related id (related anchors require related[].id)", anchor.String())
	case CommentAnchorBody:
		if anchor.ID == "" {
			return fmt.Errorf("anchor block is missing an id")
		}
		for _, b := range q.Body {
			if b.ID == anchor.ID {
				if anchor.Item == nil {
					return nil
				}
				if b.Type != BlockList {
					return fmt.Errorf("anchor %s item can only target a list block", anchor.String())
				}
				if *anchor.Item < 0 || *anchor.Item >= len(b.Items) {
					return fmt.Errorf("anchor %s item index is out of range", anchor.String())
				}
				return nil
			}
		}
		return fmt.Errorf("anchor %s does not match any body block id (block anchors require body[].id)", anchor.String())
	default:
		return fmt.Errorf("anchor kind %q is not one of quest, gate, related, body", anchor.Kind)
	}
}
