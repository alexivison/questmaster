package state

import (
	"encoding/json"
	"reflect"
	"testing"
	"time"
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

func TestStoreSetDisplayColorWritesTimestampAndPreservesUnknownKeys(t *testing.T) {
	t.Parallel()

	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(Manifest{
		SessionID: "qm-color",
		Display: &DisplayMetadata{
			Color: "cyan",
			Extra: map[string]json.RawMessage{
				"theme": json.RawMessage(`"dark"`),
			},
		},
	}); err != nil {
		t.Fatalf("create: %v", err)
	}

	if err := store.SetDisplayColor("qm-color", " Violet "); err != nil {
		t.Fatalf("set display color: %v", err)
	}

	got, err := store.Read("qm-color")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got.Display == nil {
		t.Fatal("display metadata = nil, want color metadata")
	}
	if got.Display.Color != "violet" {
		t.Fatalf("display.color = %q, want violet", got.Display.Color)
	}
	if ParseColorStamp(got.Display.ColorChangedAt).IsZero() {
		t.Fatalf("color_changed_at = %q, want timestamp", got.Display.ColorChangedAt)
	}
	if string(got.Display.Extra["theme"]) != `"dark"` {
		t.Fatalf("unknown display.theme key not preserved: %#v", got.Display.Extra)
	}
}

func TestStoreSetDisplayColorRejectsUnknownColor(t *testing.T) {
	t.Parallel()

	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(Manifest{SessionID: "qm-color", Display: &DisplayMetadata{Color: "cyan"}}); err != nil {
		t.Fatalf("create: %v", err)
	}

	if err := store.SetDisplayColor("qm-color", "brown"); err == nil {
		t.Fatal("SetDisplayColor accepted unknown color")
	}

	got, err := store.Read("qm-color")
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got.DisplayColor() != "cyan" {
		t.Fatalf("display color after invalid set = %q, want unchanged cyan", got.DisplayColor())
	}
}

func TestStoreSetDisplayColorClearKeepsExtraAndDropsEmptyDisplay(t *testing.T) {
	t.Parallel()

	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(Manifest{
		SessionID: "qm-extra",
		Display: &DisplayMetadata{
			Color:          "cyan",
			ColorChangedAt: NowColorStamp(),
			Extra: map[string]json.RawMessage{
				"theme": json.RawMessage(`"dark"`),
			},
		},
	}); err != nil {
		t.Fatalf("create extra: %v", err)
	}
	if err := store.Create(Manifest{
		SessionID: "qm-empty",
		Display:   &DisplayMetadata{Color: "cyan", ColorChangedAt: NowColorStamp()},
	}); err != nil {
		t.Fatalf("create empty: %v", err)
	}

	if err := store.SetDisplayColor("qm-extra", ""); err != nil {
		t.Fatalf("clear extra: %v", err)
	}
	if err := store.SetDisplayColor("qm-empty", ""); err != nil {
		t.Fatalf("clear empty: %v", err)
	}

	extra, err := store.Read("qm-extra")
	if err != nil {
		t.Fatalf("read extra: %v", err)
	}
	if extra.Display == nil {
		t.Fatal("clear with unknown display keys dropped display metadata")
	}
	if extra.Display.Color != "" || extra.Display.ColorChangedAt != "" {
		t.Fatalf("cleared display = %#v, want blank color fields", extra.Display)
	}
	if string(extra.Display.Extra["theme"]) != `"dark"` {
		t.Fatalf("unknown display.theme key not preserved: %#v", extra.Display.Extra)
	}

	empty, err := store.Read("qm-empty")
	if err != nil {
		t.Fatalf("read empty: %v", err)
	}
	if empty.Display != nil {
		t.Fatalf("clear with no unknown keys left display metadata: %#v", empty.Display)
	}
}

func TestStoreSetDisplayColorIgnoresWorkers(t *testing.T) {
	t.Parallel()

	store, err := NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	worker := Manifest{SessionID: "qm-worker", Display: &DisplayMetadata{Color: "cyan"}}
	worker.SetExtra("parent_session", "qm-master")
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker: %v", err)
	}

	if err := store.SetDisplayColor("qm-worker", "red"); err != nil {
		t.Fatalf("set worker color: %v", err)
	}

	got, err := store.Read("qm-worker")
	if err != nil {
		t.Fatalf("read worker: %v", err)
	}
	if got.DisplayColor() != "cyan" {
		t.Fatalf("worker color = %q, want unchanged cyan", got.DisplayColor())
	}
}

func TestStoreSetDisplayColorParticipatesInLastWriteWins(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	store, err := NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(Manifest{SessionID: "qm-color"}); err != nil {
		t.Fatalf("create: %v", err)
	}
	repoColors := NewRepoColorStore(root)
	repoIdentity := "/repo/.git"

	if err := repoColors.Set(repoIdentity, "red"); err != nil {
		t.Fatalf("set repo red: %v", err)
	}
	time.Sleep(time.Millisecond)
	if err := store.SetDisplayColor("qm-color", "violet"); err != nil {
		t.Fatalf("set session violet: %v", err)
	}

	manifest, err := store.Read("qm-color")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	repoColor, ok, err := repoColors.Get(repoIdentity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok {
		t.Fatal("repo color missing")
	}
	got := EffectiveColor(
		manifest.Display.Color,
		ParseColorStamp(manifest.Display.ColorChangedAt),
		repoColor.Color,
		ParseColorStamp(repoColor.UpdatedAt),
	)
	if got != "violet" {
		t.Fatalf("effective color after session write = %q, want violet", got)
	}

	time.Sleep(time.Millisecond)
	if err := repoColors.Set(repoIdentity, "green"); err != nil {
		t.Fatalf("set repo green: %v", err)
	}
	repoColor, ok, err = repoColors.Get(repoIdentity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok {
		t.Fatal("repo color missing after green set")
	}
	got = EffectiveColor(
		manifest.Display.Color,
		ParseColorStamp(manifest.Display.ColorChangedAt),
		repoColor.Color,
		ParseColorStamp(repoColor.UpdatedAt),
	)
	if got != "green" {
		t.Fatalf("effective color after repo write = %q, want green", got)
	}
}
