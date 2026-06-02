package quest

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
)

// questScriptRe matches the canonical JSON payload embedded in a quest file's
// <script type="application/json" id="quest"> … </script> block. Attribute
// order is not assumed; (?s) lets the payload span newlines. Build neutralizes
// any "</" in the payload to "<\/" (a valid JSON escape for "/"), so the first
// literal </script> the non-greedy group stops at is always the real closing
// tag.
var questScriptRe = regexp.MustCompile(`(?s)<script[^>]*\bid="quest"[^>]*>(.*?)</script>`)

// ExtractJSON pulls the canonical quest JSON out of a quest HTML file. It does
// not unmarshal — see Parse. Returns an error if the quest script block is
// absent.
func ExtractJSON(raw []byte) ([]byte, error) {
	m := questScriptRe.FindSubmatch(raw)
	if m == nil {
		return nil, fmt.Errorf(`quest parse: no <script type="application/json" id="quest"> block found`)
	}
	return bytes.TrimSpace(m[1]), nil
}

// Parse reads the canonical JSON from a quest HTML file and unmarshals it into
// a Quest. The generated HTML body is never parsed back; only the JSON block
// is read. Parse does not validate the schema (Validate is the separate gate).
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
	if dec.More() {
		return nil, fmt.Errorf("quest parse: unexpected trailing data after JSON object")
	}
	return &q, nil
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
// editor buffer and the Source-panel text. For embedding in the <script>
// block, build.go neutralizes the closing-tag sequence.
func Marshal(q *Quest) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(q); err != nil {
		return nil, fmt.Errorf("quest marshal: %w", err)
	}
	return bytes.TrimRight(buf.Bytes(), "\n"), nil
}
