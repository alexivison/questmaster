package state

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

const DefaultDisplayColor = "blue"

var displayColorNames = []string{
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

var displayColorANSIIndexes = map[string]string{
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
}

var displayColorSet = func() map[string]struct{} {
	set := make(map[string]struct{}, len(displayColorNames))
	for _, name := range displayColorNames {
		set[name] = struct{}{}
	}
	return set
}()

// DisplayMetadata stores user-facing presentation hints for a session.
// Extra preserves unknown nested display keys written by newer versions.
type DisplayMetadata struct {
	Color string `json:"color,omitempty"`
	// ColorChangedAt is when Color was last set (RFC3339Nano, UTC). It drives
	// last-write-wins resolution against a repo color; empty means "unknown",
	// which loses to any repo color carrying a real timestamp.
	ColorChangedAt string                     `json:"color_changed_at,omitempty"`
	Extra          map[string]json.RawMessage `json:"-"`
}

// DisplayColorOptions returns the supported named display colors.
func DisplayColorOptions() []string {
	return append([]string(nil), displayColorNames...)
}

// NormalizeDisplayColor returns a supported color name or the default.
func NormalizeDisplayColor(color string) string {
	color = strings.ToLower(strings.TrimSpace(color))
	if _, ok := displayColorSet[color]; ok {
		return color
	}
	return DefaultDisplayColor
}

// DisplayColorANSIIndex returns the ANSI palette index for a supported display
// color name. Unknown names use the default display color.
func DisplayColorANSIIndex(color string) string {
	return displayColorANSIIndexes[NormalizeDisplayColor(color)]
}

// NewDisplayMetadata creates display metadata with a valid color.
func NewDisplayMetadata(color string) *DisplayMetadata {
	return &DisplayMetadata{Color: NormalizeDisplayColor(color)}
}

func (d DisplayMetadata) IsZero() bool {
	return d.Color == "" && d.ColorChangedAt == "" && len(d.Extra) == 0
}

// DisplayColor returns the manifest's normalized display color, or an empty
// string when the manifest has no display color metadata.
func (m Manifest) DisplayColor() string {
	if m.Display == nil || strings.TrimSpace(m.Display.Color) == "" {
		return ""
	}
	return NormalizeDisplayColor(m.Display.Color)
}

// UnmarshalJSON preserves unknown nested display fields in Extra.
func (d *DisplayMetadata) UnmarshalJSON(data []byte) error {
	if bytes.Equal(bytes.TrimSpace(data), []byte("null")) {
		return nil
	}

	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '{' {
		return fmt.Errorf("display metadata must be a JSON object")
	}

	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		key, ok := tok.(string)
		if !ok {
			return fmt.Errorf("display metadata field name must be a string")
		}
		if err := d.decodeField(dec, key); err != nil {
			return err
		}
	}

	tok, err = dec.Token()
	if err != nil {
		return err
	}
	if delim, ok := tok.(json.Delim); !ok || delim != '}' {
		return fmt.Errorf("display metadata must end with a JSON object")
	}

	return ensureEOF(dec)
}

// MarshalJSON merges typed display fields with Extra to preserve unknown keys.
func (d DisplayMetadata) MarshalJSON() ([]byte, error) {
	fields := make(map[string]json.RawMessage, len(d.Extra)+2)
	if d.Color != "" {
		if err := marshalField(fields, "color", d.Color); err != nil {
			return nil, err
		}
	}
	if d.ColorChangedAt != "" {
		if err := marshalField(fields, "color_changed_at", d.ColorChangedAt); err != nil {
			return nil, err
		}
	}
	for key, raw := range d.Extra {
		if _, exists := fields[key]; exists {
			continue
		}
		fields[key] = raw
	}
	return marshalObject(fields)
}

func (d *DisplayMetadata) decodeField(dec *json.Decoder, key string) error {
	switch key {
	case "color":
		return dec.Decode(&d.Color)
	case "color_changed_at":
		return dec.Decode(&d.ColorChangedAt)
	default:
		if d.Extra == nil {
			d.Extra = make(map[string]json.RawMessage)
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return err
		}
		d.Extra[key] = raw
		return nil
	}
}
