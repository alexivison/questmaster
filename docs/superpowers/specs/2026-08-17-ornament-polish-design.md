# Ornament polish design

## Goal

Polish the shared flank rules and session pill so their baseline, scale, and hover behavior match the updated visual direction.

## Shared flank rule

`FlankedOrnamentRule.Style` gains a third case, `.simple`.

- `.default` continues to render `side-ornament.svg`.
- `.grand` continues to render `side-ornament-grand.svg`, at 85 by 37 points rather than 94 by 41 points.
- `.simple` draws native one-point hairlines. Each flank is opaque nearest the center content and fades to transparent at its outer edge. It does not load an image resource.

All three styles retain the same two-flank-and-center layout, including the existing customizable center spacing and tint.

## Section header alignment

`SectionHeader` offsets its title upward by three points inside the default flank rule. This aligns the visual bottom of the title with the ornament rule's lower edge without changing header spacing or changing other default-style consumers.

## Session pill

The selected-session pill keeps the grand flanks and its copy interaction. It no longer draws a hover background. When the copyable pill is hovered, its title and flank ornaments use the gold active color; the session identifier remains muted.

## Modal actions

`ModalSheetScaffold` wraps its existing action-button row in `.simple` so the footer regains a quiet decorative flank without reintroducing the floral SVG ornaments. Existing action order, button styles, insets, shortcuts, error layout, and footer hint remain unchanged.

## Verification

Build the Swift package and run the existing app logic test runner. Generate and inspect the section-header, terminal-top-bar, and confirmation render previews; then build/install the app bundle for manual verification.
