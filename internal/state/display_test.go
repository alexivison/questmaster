package state

import (
	"reflect"
	"testing"
)

func TestDisplayColorOptionsIncludeTrackerColors(t *testing.T) {
	t.Parallel()

	want := []string{
		"blue",
		"green",
		"yellow",
		"magenta",
		"cyan",
		"red",
		"orange",
		"gold",
		"lime",
		"teal",
		"sky",
		"indigo",
		"violet",
		"pink",
	}
	if got := DisplayColorOptions(); !reflect.DeepEqual(got, want) {
		t.Fatalf("DisplayColorOptions = %#v, want %#v", got, want)
	}
}

func TestDisplayColorANSIIndex(t *testing.T) {
	t.Parallel()

	cases := map[string]string{
		"red":     "1",
		"green":   "2",
		"yellow":  "3",
		"blue":    "4",
		"magenta": "5",
		"cyan":    "6",
		"orange":  "208",
		"gold":    "220",
		"lime":    "118",
		"teal":    "37",
		"sky":     "39",
		"indigo":  "63",
		"violet":  "177",
		"pink":    "205",
		"unknown": "4",
	}
	for color, want := range cases {
		color := color
		want := want
		t.Run(color, func(t *testing.T) {
			t.Parallel()
			if got := DisplayColorANSIIndex(color); got != want {
				t.Fatalf("DisplayColorANSIIndex(%q) = %q, want %q", color, got, want)
			}
		})
	}
}

func TestNormalizeDisplayColorAcceptsExtendedTrackerColors(t *testing.T) {
	t.Parallel()

	if got := NormalizeDisplayColor(" Violet "); got != "violet" {
		t.Fatalf("NormalizeDisplayColor extended color = %q, want violet", got)
	}
	if got := NormalizeDisplayColor("brown"); got != DefaultDisplayColor {
		t.Fatalf("NormalizeDisplayColor unknown = %q, want %q", got, DefaultDisplayColor)
	}
}
