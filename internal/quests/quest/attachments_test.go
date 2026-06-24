package quest

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestQuestAttachmentsRoundTripAndValidate(t *testing.T) {
	q := &Quest{
		ID:      "Q-ATTACH",
		Title:   "Attachment round trip",
		Status:  StatusActive,
		Summary: "Persist attachment refs",
		Attachments: []AttachmentRef{
			{ItemID: "item-1", Type: "html", Title: "Plan"},
		},
	}
	if err := Validate(q); err != nil {
		t.Fatalf("Validate: %v", err)
	}

	raw, err := Marshal(q)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if !strings.Contains(string(raw), `"attachments"`) {
		t.Fatalf("canonical JSON missing attachments:\n%s", raw)
	}

	parsed, err := ParseJSON(raw)
	if err != nil {
		t.Fatalf("ParseJSON: %v", err)
	}
	if len(parsed.Attachments) != 1 || parsed.Attachments[0].ItemID != "item-1" || parsed.Attachments[0].Type != "html" {
		t.Fatalf("parsed attachments = %#v", parsed.Attachments)
	}
}

func TestQuestAttachmentsOmitEmptyAndRejectMalformedRefs(t *testing.T) {
	q := &Quest{
		ID:      "Q-NONE",
		Title:   "No attachments",
		Status:  StatusActive,
		Summary: "No attachment refs",
	}
	raw, err := json.Marshal(q)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if strings.Contains(string(raw), `"attachments"`) {
		t.Fatalf("empty attachments should be omitted: %s", raw)
	}

	for name, ref := range map[string]AttachmentRef{
		"missing item":  {Type: "html", Title: "Plan"},
		"missing type":  {ItemID: "item-1", Title: "Plan"},
		"missing title": {ItemID: "item-1", Type: "html"},
	} {
		t.Run(name, func(t *testing.T) {
			q.Attachments = []AttachmentRef{ref}
			if err := Validate(q); err == nil {
				t.Fatalf("Validate(%#v) succeeded, want error", ref)
			}
		})
	}
}
