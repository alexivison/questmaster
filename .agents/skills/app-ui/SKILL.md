---
name: app-ui
description: Rules for any SwiftUI or AppKit view, token, colour, spacing, animation, key handling, empty or loading state or modal in Questmaster's app (app/Sources/App, app/Sources/Core). Read before editing views; covers the interaction-state looks, the 5-point spacing scale, the motion tokens, modal key routing, and the three scan tests (StateRulesScanTests, SpacingRulesScanTests, MotionRulesScanTests) that fail on a break.
---

# Questmaster app UI rules

Read this before you edit a view under `app/Sources/App` or a token under `app/Sources/Core/Rendering`. The rules most often broken come first. When this file and the live code disagree, trust the code; the scan tests are the executable authority.

## The three scan tests

They run in `swift run --package-path app QuestmasterLogicTests` and must find no breaks. Each failure message names the reference below.

| Test | Fails on | Rules |
|---|---|---|
| `StateRulesScanTests` | a raw colour outside `Theme.swift`; a `StateColor` or `textSelected` outside the token layer; `brassActive` or `ActionBarButtonLook` outside the action bar; a view picking a colour by a state flag; a hand-rolled dropdown or field | `references/interaction-states.md`, `references/shadows-and-components.md` |
| `SpacingRulesScanTests` | a raw layout number in a view (`.padding`, stack spacing, `.frame`, `EdgeInsets`, `.offset` …) outside a `*Metrics`/`*Layout`/`*Design` enum; a scale value restated as a number instead of its `Space` step; a length constant that is not a multiple of 5 | `references/spacing.md` |
| `MotionRulesScanTests` | a literal animation duration, delay or SwiftUI curve; a timing-named constant assigned a literal; a `CAMediaTimingFunction` or `.timingCurve` outside the token layer | `references/motion.md` |

The scans read lines. A value passed through a helper's parameter is not seen, so the rules still apply there. Two more self-tests measure rendered pixels for what the scans cannot see (`testRenderedSpacingStaysOnTheScale`, `testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges`).

## Rules that are not scanned

- The mouse highlights, the keys move the cursor, and a click acts. Hover never moves a list's cursor or selection (the tracker is the one exception). `references/interaction-states.md`.
- Use the shared components: `stateRow` for rows, `PillTab`/`PillTabRow` for tabs, `fieldChrome`/`FormTextField` for fields, `FilterBar`, `SuggestionDropdown`, `FilterChip`, `AngledButton`. `references/shadows-and-components.md`.
- A view asks for a state's look (`RowLook`, `OutlineLook`, `ActionBarButtonLook`, `PlateBand`) and draws it; it never picks a palette colour by state.
- Shadows come only from an `Elevation` token, never numbers at the call site, and a shadow drawn inside a clip is a bug.
- Nothing to list is one `EmptyState` icon with no text; a list still loading is a skeleton. `references/empty-loading-states.md`.
- Every in-window modal takes its keys the same way. `references/modal-keys.md`.
- A domain decision belongs in Core, not in a view callback (see the root `AGENTS.md`).

## Where each token lives

| Layer | File |
|---|---|
| Colours, fonts, elevation, state colours | `app/Sources/App/SharedUI/Theme.swift` (`AppPalette`, `AppFonts`, `Elevation`, `StateColor`) |
| Spacing, control heights, motion forms | `app/Sources/App/SharedUI/DesignTokens.swift` (`Space`, `ControlHeight`, `Motion`) |
| State looks | `app/Sources/Core/Rendering/InteractionLook.swift` |
| Motion steps and easing | `app/Sources/Core/Rendering/Motion.swift` (`MotionStep`, `MotionEasing`) |

## Before you commit a view

1. Every colour, radius and length comes from a token or a `*Metrics`/`*Layout`/`*Design` enum, and every gap is a `Space` step or a multiple of 5.
2. Every row, tab, field, dropdown and button is a shared component, and hover/cursor/selection use its look.
3. Every transition takes a `MotionStep` and the shared easing; Reduce Motion skips it.
4. `swift build --package-path app` and `swift run --package-path app QuestmasterLogicTests` pass. UI is not unit-tested; leave interactive GUI checks to the human (no AppleScript).

## References

- `references/interaction-states.md`: pointer/key/hover rules, focus rules, the state table, the `StateRulesScanTests` rule.
- `references/shadows-and-components.md`: bold, dividers, brass, elevation shadows, the shared component list.
- `references/empty-loading-states.md`: `EmptyState`, skeletons, the tracker's connection state.
- `references/modal-keys.md`: the key rules every modal follows, and the non-modal lists' keys.
- `references/spacing.md`: the 5s scale, control heights, the three scan rules.
- `references/motion.md`: motion steps, easing, Reduce Motion, modal entrance, the three scan rules.

Decided behaviour of one surface (tracker, Worker Log, Watcher, dock, action bar, Quest Log) is in `app-surfaces`.

Testing detail: `Questmaster --render-preview <dir>` (DEBUG; `RENDER_ONLY=name,...`, `RENDER_SCALE=2`) renders the fixtures off-screen. `RenderPreview.renderView` hosts each in a frame-based container, not as the window's content view: a content view's constraints give the window a minimum size, and a hosting view nested in them (a dock panel's body) reports its content's minimum, wrapped text at zero width, so a render came out taller than asked.
