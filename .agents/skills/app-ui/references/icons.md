# Icons

Every decided glyph is drawn through `AppIcon` (`app/Sources/App/SharedUI/AppIcon.swift`), from the SVGs in
`app/Sources/App/Resources/Icons/line` (one per glyph) and `Resources/Icons/filled` (the filled drawing, where it has one;
the dock's close, back and refresh, the Projects page's five and the viewer's shield are line-only). The SVGs are the source of truth and are bundled unchanged. `AppIcon`
reads each as a coverage mask and fills it with the caller's tint, so a glyph takes any colour and its stroke scales with
its size.

## The drawing rule

Every drawing is 24 units with a 1.5 stroke, round caps and joins. `#000000` is ink, and `#ffffff` is a knock-out that shows
the tile through. Keylines, so the set reads at one size, like the SF Symbols:

- a round shape fills a 20-unit circle (cog, globe);
- a square-ish shape fills an 18 box;
- a tall shape is 20 high, and a wide one 20 wide;
- a bare stroke (cross, back arrow) is 16.

Shapes are not redrawn to fit. Only scale and centring move. A new drawing follows the same rule.

## Sizing a surface

A call site sets one glyph side for its surface, not one per icon. The side is set by ink, not by the point size of the SF
Symbol it replaced: measure the visible ink box at 2x (a pixel at least half covered) for the old symbol, as the call drew it
(including any aspect-fit into its canvas), and for each new drawing at candidate sides. Pick the side that minimises the
largest per-axis deviation across the surface's icons. Keep the side on the 5s where a `*Metrics` name is a length (the
spacing scan), and say where a surface stays more than 2pt out and why (usually a shape difference, not a size one).

The sides the set currently uses, and the constants that carry them: `ActionBarMetrics.iconSide` (25 in a 30pt button),
`SettingsMetrics.sectionIconSide` (20, the tab's icon square, and the Projects row's quill, move arrows and add),
`ArtifactRow.Metrics.iconSide` (30 in the 40pt tile), `ChromeMetrics.glyphSide` (20, the hit square; the Projects header
uses it too), `ArtifactRow.Metrics.markSide` (20, the gutter), the disc glyph (the logo's side; the shell rows and the
selected-session panel use it too), the status panes (`ControlHeight.compact`, 25) and the empty state (`Token.Size.emptyIcon`, 40). The casts are not
sized here: `TrackerCastIcon` fits each cast's ink to the layout's `iconSide`.
