package session

import (
	"regexp"
	"strings"
)

// titleMaxWords caps how many leading words a derived title keeps.
const titleMaxWords = 6

// titleMaxRunes hard-caps the derived title length. It stays well under the
// picker form's 64-rune input limit and Claude's --name budget.
const titleMaxRunes = 48

var (
	// fencedCodeBlock matches triple-backtick fenced blocks (including the
	// fence lines) so pasted code doesn't leak into the title.
	fencedCodeBlock = regexp.MustCompile("(?s)```.*?```")
	// inlineCode matches single-backtick spans; the backticks are stripped
	// but the inner text is kept (it's often the meaningful subject).
	inlineCode = regexp.MustCompile("`([^`]*)`")
	// urlPattern matches bare http(s) URLs, which make poor titles.
	urlPattern = regexp.MustCompile(`https?://\S+`)
	// whitespaceRun collapses any run of whitespace to a single space.
	whitespaceRun = regexp.MustCompile(`\s+`)
)

// TitleFromPrompt derives a short, human-readable session title from a user's
// first message. It strips code and URLs, collapses whitespace, and keeps the
// leading clause. It returns "" when nothing usable remains, so callers can
// keep the title blank rather than persist a meaningless value.
func TitleFromPrompt(prompt string) string {
	s := fencedCodeBlock.ReplaceAllString(prompt, " ")
	s = inlineCode.ReplaceAllString(s, "$1")
	s = urlPattern.ReplaceAllString(s, " ")

	// Use the first non-empty line as the basis for the title.
	for _, line := range strings.Split(s, "\n") {
		if strings.TrimSpace(line) != "" {
			s = line
			break
		}
	}

	s = strings.TrimSpace(whitespaceRun.ReplaceAllString(s, " "))
	if s == "" {
		return ""
	}

	words := strings.Fields(s)
	if len(words) > titleMaxWords {
		words = words[:titleMaxWords]
	}
	title := strings.Join(words, " ")

	return truncateRunes(title, titleMaxRunes)
}

// truncateRunes shortens s to at most max runes, trimming any trailing space
// left by the cut.
func truncateRunes(s string, max int) string {
	runes := []rune(s)
	if len(runes) <= max {
		return s
	}
	return strings.TrimRight(string(runes[:max]), " ")
}
