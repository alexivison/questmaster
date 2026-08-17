# Sprig ornament design

## Goal

Add the supplied botanical flank as a reusable `FlankedOrnamentRule` style and use it for the artifact scope tabs.

## Shared style

`FlankedOrnamentRule.Style` gains `.sprig`.

- Import `/Users/aleksi.tuominen/Downloads/ornaments/side-ornament-2.svg` unchanged as `side-ornament-2.svg`.
- Use its intrinsic 111 by 23 point canvas.
- Preserve the SVG’s botanical flourish nearest the center with a trailing cap inset; only the outer line region may stretch.
- Keep the shared tint, center spacing, and full-width flank behavior used by the existing SVG styles.

## Artifact scope tabs

`SegmentedPicker` renders the `.sprig` style beneath each artifact scope tab instead of the default flank. The current selected/unselected colors and 11-point tab-rule layout height remain unchanged.

## Tracker header spacing

`TrackerRepoSection` uses eight points for both the top and bottom inset supplied to its `SectionHeader`. This preserves the tracker-only spacing override while making the visible space above and below each separator equal.

## Verification

Build the Swift package and run the existing logic test runner. Generate and inspect the artifact-list render preview, including both selected and unselected scope tabs, then rebuild and code-sign verify `/Applications/Questmaster.app` for manual review.
