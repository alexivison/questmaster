package session

import "testing"

func TestTitleFromPrompt(t *testing.T) {
	tests := []struct {
		name   string
		prompt string
		want   string
	}{
		{"empty", "", ""},
		{"whitespace only", "   \n\t ", ""},
		{"simple imperative", "fix the login flow", "fix the login flow"},
		{"trims surrounding space", "   refactor the parser   ", "refactor the parser"},
		{"collapses whitespace", "add\t\tretry   logic", "add retry logic"},
		{"caps at six words", "one two three four five six seven eight", "one two three four five six"},
		{"uses first non-empty line", "\n\n  investigate flaky test\nmore detail here", "investigate flaky test"},
		{"strips fenced code", "explain this ```go\nfunc main(){}\n``` please", "explain this please"},
		{"keeps inline code text", "rename `getUser` to `fetchUser`", "rename getUser to fetchUser"},
		{"drops urls", "open https://example.com/very/long/path now", "open now"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := TitleFromPrompt(tc.prompt); got != tc.want {
				t.Fatalf("TitleFromPrompt(%q) = %q, want %q", tc.prompt, got, tc.want)
			}
		})
	}
}

func TestTitleFromPromptCapsRuneLength(t *testing.T) {
	// A single very long word must be truncated to the rune cap.
	long := ""
	for range 100 {
		long += "x"
	}
	got := TitleFromPrompt(long)
	if len([]rune(got)) != titleMaxRunes {
		t.Fatalf("len = %d runes, want %d", len([]rune(got)), titleMaxRunes)
	}
}

func TestTitleFromPromptMultibyte(t *testing.T) {
	got := TitleFromPrompt("修正 ログイン フロー")
	if got != "修正 ログイン フロー" {
		t.Fatalf("multibyte title = %q", got)
	}
}
