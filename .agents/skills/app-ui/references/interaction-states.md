# Interaction states

One set of state rules covers the whole app. A view asks for a state's look
(`RowLook`, `OutlineLook`, `ActionBarButtonLook`, `PlateBand` in
`Core/Rendering/InteractionLook.swift`) and draws it; it never picks a palette
colour by state itself. The colours are `StateColor` cases, which `AppPalette`
builds its matching entries from (`SharedUI/Theme.swift`).

The mouse highlights, the keys move the cursor, and a click acts. The pointer
shows the hover look (`RowLook.hovered`: a 1pt `line` outline, no fill, text
and icon unchanged; `controlBorder` on a raised surface, where `line` barely
shows; every cursor and selection look is filled, so the two never read alike)
on the row under it, via `stateRow`, and moves no list's cursor or
selection. Return, Tab and Save
commit the keyboard cursor; a row the pointer only crossed needs a click. The
one exception is the tracker while it has the keys: hover moves its cursor
(`highlightOnHover`, real pointer motion only), and its list doesn't scroll to
a cursor the pointer moved, and drops a key scroll still queued
(`PointerCursor`). A pill tab is already `item`
filled, so tabs have no hover look.

A region has the keys while it's focused and no modal is drawn
(`NavigationStore.hasKeys`); its focus looks follow that. Inside the dock only
the focused panel has them (`NavigationStore.hasKeys(_: DockPanel)`). When the
user leaves a region or panel, a selection that lasts (a tab row's) and a
cursor whose design draws an unfocused state (the artifact list's) stay one
step dimmer; a pure cursor with no lasting selection and no designed unfocused
state (the tracker's, Watcher's: `RowLook.cursor`) hides, and shows
again where it was when the keys come back.

| Element | State | Look |
|---|---|---|
| Pick-to-open row (artifacts, dropdowns, filter suggestions) | rest | no fill, `textBody` #ADBAC7, icon tile border `line`, icon and meta `textMeta` #8D9AA8 |
| | highlighted, area focused (`RowLook.highlighted`) | `item` fill, `textSelected` #C4D0DC, icon tile border `controlBorder`, icon `textSelected`, meta `textMetaHighlighted` #9DA7B1 |
| | highlighted, area unfocused (`RowLook.highlightedUnfocused`) | `item` fill, `textBody` text and icon, icon tile border `controlBorder`, meta `textMeta` #8D9AA8 |
| | missing file (`RowLook.missingFile`) | the row's look with a `warn` icon |
| | marked for deletion (`MarkLook`) | `accent` diamond in the row's left gutter |
| Any row | under the pointer (`RowLook.hovered`) | 1pt `line` outline, no fill; text, icon and meta as at rest |
| Row on a raised surface (the Worker Log filter's dropdown, drawn in `item`) | rest (`RowLook.raisedRest`) | no fill, `textBody`, icon and meta as at rest |
| | highlighted (`RowLook.raisedHighlighted`) | `line` fill, one step above the surface (an `item` fill would vanish on it), `textSelected`, meta `textMetaHighlighted` |
| | under the pointer | 1pt `controlBorder` outline, no fill; text, icon and meta as at rest |
| Lasting-selection row (the Quest Log) | selected (`RowLook.selected`) | `item` fill, **bold** `textSelected` |
| Tab (agent tabs, Session/All, Settings sidebar) | rest (`OutlineLook.tabRest`) | `line` outline, `textBody` |
| | selected (`.tabSelected`) | `controlBorder` outline, `textSelected` |
| | selected, area unfocused (`.tabSelectedUnfocused`) | `controlBorder` outline, `textBody` |
| Text tab (the Worker Log's worker tabs) | rest (`TextTabLook.rest`) | no outline or fill, `textMeta`, regular |
| | under the pointer (`.hovered`) | `textBody`, regular |
| | selected (`TextTabLook.tab`) | **bold**, the selected pill tab's label colour: `textSelected` while the panel has the keys, `textBody` without them; the pointer adds nothing |
| Field | rest / focused (`.fieldRest` / `.fieldFocused`) | `line` / `controlBorder` border (`fieldChrome`) |
| Dock panel frame | rest / focused (`.frameRest` / `.frameFocused`) | 2pt `lineSoftSubtle` / `controlBorder` |
| Icon button (dock top bar) | rest / under the pointer | `RowLook` icon: `textMeta` / `textSelected` |
| Action bar button (`ActionBarButtonLook`) | rest / active (the tracker or the dock panel it opens shows) / under the pointer | `item` fill and `line` border in every state; icon `textMeta` / `textBody` / `textSelected` |
| | toggle on (caffeinate) | icon unchanged; a 2pt `brassActive` inner glow at 15% and the tracker's working spinner (`SpinnerRingView`) turning round the 1pt border |
| Tracker plate | cursor, while the tracker has the keys (`PlateBand.showsCursor`) / under the pointer / recolouring | `textSelected` / `controlBorder` / `accent` band; no band otherwise |
| | attached: the session open in the terminal (`TrackerAttachedDot`) | a 5pt dot (`Space.row`) in the project colour (`TrackerNameplateColor.barLightness`, the project name's and side diamonds'), its centre `Space.item` left of the disc's left edge and level with the disc's centre; no shadow, no band, hit shape, layout or number change |
| Shell row (the tracker's shell rows) | rest (`RowLook.shellRest`) | no fill, title and glyph `textMeta`, glyph disc `item` rim (a filled row's disc takes the look's own rim) |
| | under the pointer | the hover look (1pt `line` outline), on a resting row only |
| | keyboard cursor, while the tracker has the keys (`RowLook.shellCursor`) | 1pt `controlBorder` outline inside the row, no fill, text and glyph as at rest, regular weight |
| | the viewed shell (`RowLook.selected`) | `item` fill, **bold** `textSelected` |
| | the cursor on the viewed shell (`RowLook.shellSelectedCursor`) | the fill and bold, plus the `controlBorder` outline |


`StateRulesScanTests` (in the logic-test runner) scans `app/Sources/App` and
fails on a raw colour outside `Theme.swift`, a `StateColor`/`textSelected`
outside the token layer, `brassActive` or `ActionBarButtonLook` outside the action bar, a
view picking a colour by a state flag, and a hand-rolled dropdown or field. It
must find no breaks.
