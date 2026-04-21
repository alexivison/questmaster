package tmux

import (
	"reflect"
	"slices"
	"testing"
)

func TestIsProgressLine(t *testing.T) {
	t.Parallel()

	cases := map[string]struct {
		line string
		want bool
	}{
		"tool-exec spinner glyph middle-dot": {
			line: "· Warping… (2m 50s · ↓ 9.1k tokens)",
			want: true,
		},
		"tool-exec spinner glyph sparkle": {
			line: "✻ Drizzling… (3m 40s · ↓ 13.4k tokens)",
			want: true,
		},
		"tool-exec spinner with thought-for suffix": {
			line: "✢ Drizzling… (4m 3s · ↓ 15.2k tokens · thought for 17s)",
			want: true,
		},
		"tool-exec spinner with upload tokens": {
			line: "✽ Crunching… (14s · ↑ 0.1k tokens)",
			want: true,
		},
		"tool-exec spinner glyph asterisk-only": {
			line: "✳ Pondering… (22s · ↓ 1.2k tokens)",
			want: true,
		},
		"thinking with esc to interrupt": {
			line: "✳ Lollygagging… (14s · esc to interrupt · ctrl+t to show todos)",
			want: true,
		},
		"thinking-with phrase only": {
			line: "something thinking with high effort",
			want: true,
		},
		"idle post-completion worked-for": {
			line: "✻ Worked for 1m 56s",
			want: false,
		},
		"user input prompt": {
			line: "› Great, some user prompt",
			want: false,
		},
		"tool call announcement": {
			line: "⏺ Bash(some command)",
			want: false,
		},
		"empty line": {
			line: "",
			want: false,
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if got := IsProgressLine(tc.line); got != tc.want {
				t.Fatalf("IsProgressLine(%q) = %v, want %v", tc.line, got, tc.want)
			}
		})
	}
}

func TestFilterAgentLinesIncludesToolExecProgress(t *testing.T) {
	t.Parallel()

	raw := "⏺ Bash(party-cli relay long command)\n" +
		"⎿  Running…\n" +
		"\n" +
		"· Warping… (2m 50s · ↓ 9.1k tokens)\n"

	got := FilterAgentLines(raw, 4)
	progress := "· Warping… (2m 50s · ↓ 9.1k tokens)"
	if !slices.Contains(got, progress) {
		t.Fatalf("FilterAgentLines() = %#v, want to contain %q", got, progress)
	}
}

func TestFilterAgentLinesExcludesUserInputPrefixes(t *testing.T) {
	t.Parallel()

	raw := "❯ user prompt\n› partial prompt\n⏺ Running...\n⎿ Tool output\n  details\n✳ Thinking… (esc to interrupt)\n"

	got := FilterAgentLines(raw, 10)
	want := []string{
		"⏺ Running...",
		"⎿ Tool output",
		"details",
		"✳ Thinking… (esc to interrupt)",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("FilterAgentLines() = %#v, want %#v", got, want)
	}
}

func TestFilterCodexLinesExcludesUserInputPrefixes(t *testing.T) {
	t.Parallel()

	raw := "❯ user prompt\n› partial prompt\n⏺ Running...\n• note\n⎿ Tool output\n  details\n"

	got := FilterCodexLines(raw, 10)
	want := []string{
		"⏺ Running...",
		"• note",
		"⎿ Tool output",
		"details",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("FilterCodexLines() = %#v, want %#v", got, want)
	}
}
