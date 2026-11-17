# Spacing

Everything is on 5s. Every gap, margin, padding, inset, pitch and control size
is a multiple of 5, and spacing takes one of four steps (`Space` in
`SharedUI/DesignTokens.swift`), or a sum of them:

| Step | Value | Role |
|---|---|---|
| `Space.row` | 5 | rows of one list control; a field and its dropdown; collapsed circles; the cast row under its disc |
| `Space.item` | 10 | sibling items (plates, tabs, buttons, chat entries, bar icons); icon → text; text inset inside a control; a panel title's text frame → the next element of its header, and between two elements of one header (`PanelHeaderMetrics.elementGap`) |
| `Space.section` | 20 | the shell gap (`ShellMetrics.gap`); every panel's edge margin; blocks inside a panel; a panel's header → its content (`PanelHeaderMetrics.contentGap`) |
| `PanelMetrics.contentInset` | 20 (`Space.section`) | a dock panel's or a modal's outer side margin, on both sides: rows, cards, fields, tab rows, footer rules. Every panel and modal reads this one token; a panel's list that scrolls keeps it: its indicator is `.never` (`SectionedList(indicators:)`; a hidden one still takes its width from the rows). The tracker's list keeps `.hidden`. Where a bottom corner's scoop reaches in, the inset is the scoop's (the Worker Log tab row, 35) |
| `Space.group` | 40 | between groups of blocks: the plate list → the avatar slot |

Control heights are one family (`ControlHeight`): `chip` 15, `compact` 25
(pill tabs, text tab rows, Quest Log title lines), `control` 30 (buttons, dropdown rows), `field` 35
(fields, filters, the Settings picker), `bar` 40 (the dock top bar), `row` 50
(artifact, quest and project cards). A shape drawn from a design at another height keeps its path's
own height as an `svg…` constant and scales to the control's.

Not spacing, so free of the rule: text baselines and line heights, a glyph's
optical nudge, radii and stroke widths, 0/1 spacers, and `svg…` lengths in an
SVG's own coordinates: path data, and an art's own size where no uniform scale
lands both sides on 5s. A design value that
isn't on 5s is snapped to the nearest 5 or redrawn onto 5s, never kept with a
marker.

`SpacingRulesScanTests` (in the logic-test runner) enforces it and must find no
breaks:

- **raw-spacing**: no layout number in a view (`.padding`, stack and grid
  `spacing`, `.frame` sizes, `Spacer(minLength:)`, `EdgeInsets`, constraint
  constants, `.offset`, `.position`), except 0 and 1 and lines inside an `enum`
  named `*Metrics`, `*Layout` or `*Design`. A number in a ternary branch, added
  to a step (`Space.item + 3`) or scaling one (`Space.item * 1.3`) counts;
  halving or doubling (`2 * border`, `/ 2`, `* 0.5`) and an inner call's own
  arguments don't. A `//` inside a string is no comment.
- **scale-restated**: a gap/inset/spacing/margin/padding/gutter constant of 5,
  10, 20 or 40 names its `Space` step.
- **off-rhythm**: a CGFloat constant or default named as a length (gap,
  spacing, margin, padding, gutter, pitch, indent, inset, clearance, offset,
  height, width, side, size, lead, trail, nudge, origin; x and y for a static or
  metrics constant, not a local in path code) is a multiple of
  5, and so is each number of an `NSSize`/`CGSize` assigned to an inset,
  padding, margin or gap, metrics enums included. Only names that say they aren't
  spacing are exempt (`baseline`, `lineHeight`, `radius`, `stroke`, `border`,
  `ring`, `glow`, `pointSize`, `font`, a `glyph` nudge, and `svg` coordinates).

The scan reads lines, so `testRenderedSpacingStaysOnTheScale` (a
`--run-logic-tests` self-test) measures rendered pixels for what it can't see:
the artifact cards' 55pt pitch, their 40pt icon tiles, and a form's fields 20 under the modal header and
20 apart. `testPanelHeadersSpaceTheirElementsTenAndTwentyUnderTheTitle` measures the headers the same way: the
Artifacts tabs' filter 10 under the tabs and the first card 20 under the filter, the Watcher's first row 20 under the
title, and a modal's chapter rule 10 under the title. The header's own rhythm is in `PanelHeaderMetrics`
(`SharedUI/PanelHeader.swift`); the header's elements and the dock titles are in `app-surfaces`.

