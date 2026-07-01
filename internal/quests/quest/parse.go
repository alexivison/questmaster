package quest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
)

// questScriptRe matches the canonical JSON payload embedded in a quest file's
// <script type="application/json" id="quest"> … </script> block. Attribute
// order is not assumed; (?s) lets the payload span newlines. Build neutralizes
// any "</" in the payload to "<\/" (a valid JSON escape for "/"), so the first
// literal </script> the non-greedy group stops at is always the real closing
// tag.
var questScriptRe = regexp.MustCompile(`(?s)<script[^>]*\bid="quest"[^>]*>(.*?)</script>`)

// ExtractJSON pulls the canonical quest JSON out of a legacy quest HTML file. It
// does not unmarshal — see Parse. Returns an error if the quest script block is
// absent.
//
// The old HTML build emitted the canonical block last, after the body — where a
// raw rich-html block could carry its own id="quest" script and shadow the real
// source of truth. So we take the LAST match, which is the guaranteed-canonical
// block, rather than the first.
// ponytail: transitional; retained only to migrate pre-JSON quests on read.
func ExtractJSON(raw []byte) ([]byte, error) {
	ms := questScriptRe.FindAllSubmatch(raw, -1)
	if len(ms) == 0 {
		return nil, fmt.Errorf(`quest parse: no <script type="application/json" id="quest"> block found`)
	}
	return bytes.TrimSpace(ms[len(ms)-1][1]), nil
}

// Parse reads the canonical JSON from a legacy quest HTML file and unmarshals it
// into a Quest. Only the embedded JSON block is read; the HTML body was always
// derived. New quests are stored as bare JSON — see ParseJSON. Parse does not
// validate the schema (Validate is the separate gate).
// ponytail: transitional; retained only to migrate pre-JSON quests on read.
func Parse(raw []byte) (*Quest, error) {
	data, err := ExtractJSON(raw)
	if err != nil {
		return nil, err
	}
	return ParseJSON(data)
}

// ParseJSON unmarshals bare canonical quest JSON into a Quest. Used by the edit
// flow, which re-reads the JSON a human edited in $EDITOR.
func ParseJSON(data []byte) (*Quest, error) {
	var q Quest
	dec := json.NewDecoder(bytes.NewReader(data))
	if err := dec.Decode(&q); err != nil {
		return nil, fmt.Errorf("quest parse: malformed JSON: %w", err)
	}
	// Decoder.More only reports remaining elements inside the current
	// array/object — it does not reject a second top-level value, so a buffer
	// like `{...}{...}` would otherwise parse as the first object and silently
	// drop the rest. A second Decode must hit clean io.EOF: any decodable value
	// (or trailing non-whitespace) means the buffer is not a lone JSON object.
	if err := dec.Decode(new(json.RawMessage)); err != io.EOF {
		return nil, fmt.Errorf("quest parse: unexpected trailing data after JSON object")
	}
	return &q, nil
}

func canonicalQuest(q *Quest) *Quest {
	if q == nil || q.Agent == "" {
		return q
	}
	cp := *q
	cp.Agent = ""
	return &cp
}

// UnmarshalJSON accepts either the structured object form
// ({"type","title","url"}) or a bare string (which becomes the Title), so
// older quests authored with plain string related entries still parse.
func (r *RelatedLink) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) > 0 && trimmed[0] == '"' {
		var s string
		if err := json.Unmarshal(trimmed, &s); err != nil {
			return err
		}
		*r = RelatedLink{Title: s}
		return nil
	}
	type alias RelatedLink
	var a alias
	if err := json.Unmarshal(trimmed, &a); err != nil {
		return err
	}
	*r = RelatedLink(a)
	return nil
}

// Marshal renders a Quest as canonical, human-readable JSON (two-space indent,
// HTML left unescaped so authored rich content stays legible). This is the
// stored quest file and the $EDITOR buffer.
func Marshal(q *Quest) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(canonicalQuest(q)); err != nil {
		return nil, fmt.Errorf("quest marshal: %w", err)
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}
