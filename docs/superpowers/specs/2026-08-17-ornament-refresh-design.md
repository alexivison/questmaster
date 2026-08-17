# Ornament refresh design

## Scope

Refresh the native app's shared flank ornaments, session pill, tracker footer,
and artifact viewer header using the three supplied SVG assets.

## Shared flanked rule

`FlankedOrnamentRule` gains a style choice with `.default` and `.grand`.
Each style renders the corresponding SVG resource on both sides of its center
content, mirrored so the artwork faces inward. The existing color input remains
the tint source for the default style's current callers. Flanks preserve the
asset aspect ratio and shrink together only in narrow containers, avoiding
horizontal overflow.

`.default` is the rule's default and replaces the current hand-drawn flourish
everywhere it is used: list section headers, modal chapter rules, and segmented
picker dividers. The artifact viewer header stops using the rule, so it remains
plain as requested.

## Session pill

`ChromeSessionChip` uses `FlankedOrnamentRule(style: .grand)` around its title
and optional session ID. Its current stretched `session_frame.svg`, rounded
border fallback, and corner ornaments are removed. The copy interaction,
hover background, typography, and sizing remain unchanged.

## Tracker end ornament

The tracker appends `tracker-end-ornament.svg` after its populated session
sections only when the existing list content plus the ornament's height fits in
the scroll viewport. The decision is based on measured content and viewport
heights before adding the ornament, so the ornament can never introduce
scrolling. Empty and loading tracker states do not show it.

## Assets and verification

Add the three supplied SVGs to `app/Sources/App/Resources/Ornaments` and load
them through the existing resource-image helper. Add a focused logic test for
the fit decision's boundary cases, then run the app build and its Core logic
test executable.
