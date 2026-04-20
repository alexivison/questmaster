package tmux

import (
	"reflect"
	"testing"
)

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

func TestFilterWizardLinesExcludesUserInputPrefixes(t *testing.T) {
	t.Parallel()

	raw := "❯ user prompt\n› partial prompt\n⏺ Running...\n• note\n⎿ Tool output\n  details\n"

	got := FilterWizardLines(raw, 10)
	want := []string{
		"⏺ Running...",
		"• note",
		"⎿ Tool output",
		"details",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("FilterWizardLines() = %#v, want %#v", got, want)
	}
}
