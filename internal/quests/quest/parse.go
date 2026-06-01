package quest

import (
	"encoding/json"
	"fmt"
	"html"
	"strings"
)

// HeadElementID is the id of the canonical head element in the quest file.
const HeadElementID = "quest-head"

// Parse extracts the canonical JSON head (the element with id="quest-head")
// and returns it as a Quest together with the raw document as the Body. It
// mirrors what a browser sees via .textContent: syntax-highlight spans are
// stripped, HTML entities unescaped. Parse is structural only — schema rules
// are enforced separately by Validate.
func Parse(htmlBytes []byte) (*Document, error) {
	headText, err := extractHead(string(htmlBytes))
	if err != nil {
		return nil, err
	}

	jsonText := normalizeJSONStringWhitespace(html.UnescapeString(headText))

	var q Quest
	dec := json.NewDecoder(strings.NewReader(jsonText))
	if err := dec.Decode(&q); err != nil {
		return nil, fmt.Errorf("parse quest head JSON: %w", err)
	}

	// Body preserves the original document verbatim so `quest open` renders
	// exactly what was authored and Save→Load round-trips byte-for-byte.
	body := make([]byte, len(htmlBytes))
	copy(body, htmlBytes)
	return &Document{Head: q, Body: body}, nil
}

// extractHead returns the inner text of the element carrying id="quest-head",
// with all child tags (the syntax-highlight spans) removed — i.e. its
// textContent. It is robust to the head element nesting other elements, and to
// the id being *mentioned* inside an HTML comment (the template's authoring
// notes reference <pre id="quest-head">), which must not be mistaken for the
// real element.
func extractHead(raw string) (string, error) {
	s := blankHTMLComments(raw)
	idx := strings.Index(s, `id="`+HeadElementID+`"`)
	if idx < 0 {
		idx = strings.Index(s, `id='`+HeadElementID+`'`)
	}
	if idx < 0 {
		return "", fmt.Errorf("quest head not found: no element with id=%q", HeadElementID)
	}

	open := strings.LastIndexByte(s[:idx], '<')
	if open < 0 {
		return "", fmt.Errorf("quest head malformed: no opening tag before id=%q", HeadElementID)
	}
	nameStart := open + 1
	nameEnd := nameStart
	for nameEnd < len(s) && isTagNameByte(s[nameEnd]) {
		nameEnd++
	}
	tagName := s[nameStart:nameEnd]
	if tagName == "" {
		return "", fmt.Errorf("quest head malformed: empty tag name")
	}

	gt := strings.IndexByte(s[idx:], '>')
	if gt < 0 {
		return "", fmt.Errorf("quest head malformed: unterminated opening tag")
	}
	contentStart := idx + gt + 1

	openTag := "<" + tagName
	closeTag := "</" + tagName
	depth := 1
	pos := contentStart
	for {
		nc := indexTagFrom(s, closeTag, pos)
		if nc < 0 {
			return "", fmt.Errorf("quest head malformed: missing closing </%s>", tagName)
		}
		no := indexTagFrom(s, openTag, pos)
		if no >= 0 && no < nc {
			depth++
			pos = no + len(openTag)
			continue
		}
		depth--
		if depth == 0 {
			return stripTags(s[contentStart:nc]), nil
		}
		pos = nc + len(closeTag)
	}
}

// blankHTMLComments replaces the bytes inside <!-- ... --> comments (and the
// markers) with spaces, preserving length and offsets of all non-comment
// content so positions in the returned string match the input.
func blankHTMLComments(s string) string {
	const open, close = "<!--", "-->"
	out := []byte(s)
	for i := 0; i < len(out); {
		start := strings.Index(string(out[i:]), open)
		if start < 0 {
			break
		}
		start += i
		end := strings.Index(string(out[start+len(open):]), close)
		if end < 0 {
			// Unterminated comment: blank to end of document.
			end = len(out)
		} else {
			end = start + len(open) + end + len(close)
		}
		for j := start; j < end; j++ {
			if out[j] != '\n' {
				out[j] = ' '
			}
		}
		i = end
	}
	return string(out)
}

// indexTagFrom finds tag (e.g. "<code" or "</code") starting at from, but only
// where it forms a real tag boundary (the next byte ends the tag name), so
// "<code" does not match inside "<codex".
func indexTagFrom(s, tag string, from int) int {
	for from <= len(s)-len(tag) {
		i := strings.Index(s[from:], tag)
		if i < 0 {
			return -1
		}
		abs := from + i
		after := abs + len(tag)
		if after >= len(s) || !isTagNameByte(s[after]) {
			return abs
		}
		from = abs + len(tag)
	}
	return -1
}

// stripTags removes every <...> tag, leaving the textContent.
func stripTags(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	inTag := false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '<':
			inTag = true
		case '>':
			inTag = false
		default:
			if !inTag {
				b.WriteByte(s[i])
			}
		}
	}
	return b.String()
}

// normalizeJSONStringWhitespace collapses runs of raw whitespace that appear
// inside a JSON string literal to a single space. Quest heads wrap long string
// values across source lines for readability (e.g. the goal in the canonical
// template), which puts a literal newline + indentation inside the string —
// rejected by strict encoding/json. Whitespace between tokens (outside
// strings) is left untouched for the decoder.
func normalizeJSONStringWhitespace(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	var last byte
	inString := false
	escaped := false
	write := func(c byte) {
		b.WriteByte(c)
		last = c
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !inString {
			write(c)
			if c == '"' {
				inString = true
				escaped = false
			}
			continue
		}
		if escaped {
			write(c)
			escaped = false
			continue
		}
		switch c {
		case '\\':
			write(c)
			escaped = true
		case '"':
			write(c)
			inString = false
		case '\n', '\r', '\t':
			if last != ' ' {
				write(' ')
			}
			for i+1 < len(s) && isRawSpace(s[i+1]) {
				i++
			}
		default:
			write(c)
		}
	}
	return b.String()
}

func isRawSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

func isTagNameByte(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == ':'
}
