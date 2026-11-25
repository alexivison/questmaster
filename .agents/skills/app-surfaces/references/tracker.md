# Tracker

- The attached dot follows the attached session, never the cursor or the pointer. A master's or an expanded worker's own
  plate carries it; a worker shown only as a collapsed circle puts it on its master's plate; a shell carries none (its
  filled, bold row marks it), and neither does nothing attached. It sits in the list's leading gutter (a master's reaches
  12.5 left of its row), drawn outside the plate's silhouette layers, which clip at their margin.
- Shells are not plates: every shell, tmux and orphan row leaves its repo group for the shell rows (`TrackerShellSection`,
  drawn by `TrackerShellRow`), pinned below the avatar's session banner. A shell's own display colour tints its title in every
  state; none leaves the state's text colour.

Spacing of the tracker's portraits and shell section (the general scale is `.agents/skills/app-ui/references/spacing.md`). Portraits sit on 5s too: the master's disc spans 0-50 and the worker's 20-60 in
their rows, and plate text starts `Space.row` past the disc's round edge (55,
65; the side diamonds don't count). Logos are 0.6 of their disc (30, 24, 15),
canvases and icon, logo and mark sizes are lengths like any other. A plate disc with a class portrait carries its
agent's logo in a 25pt badge (logo 15), as big as a collapsed worker's circle, whose edge hangs `Space.row` outside the
disc on the left and below it (`TrackerPlateDesign.badgeOverhang`); the sheets' title row is a 40pt portrait disc, `Space.item`, then the 35pt field.
A shell row is 35 high (`ControlHeight.field`) and as wide as the 240pt plate column, flush with the plates, stacked with no gap
(the tracker mock's layout, not Shell Session.svg's inset and spaced rows), with a 25pt disc (`ControlHeight.compact`) 10
in and the title 10 past it. The shell section is pinned to the bottom of the tracker column (`verticalPadding` from its
edge), as tall as its rows up to `TrackerShellMetrics.maxHeight` (175, five rows), and scrolls inside itself past that;
the plates scroll in their own list above it. A static banner (`TrackerHeader`, from `Tracker Header.svg`) tops the column in
the action bar header's band: as tall as it (`TrackerListMetrics.headerHeight`) and as wide as the tracker column, from the plates'
left edge through the PR badge column's right edge (`TrackerListMetrics.columnWidth`, 280: the 240 plates and the 40 badge column; the
2pt band allowance past it is not covered), so it covers the chips' column even with no watches. Its left edge is the plates' column
(`TrackerListMetrics.sidePadding`; the disc starts there, only a plate's agent badge hangs `badgeOverhang` outside), and its top and
bottom edges are level with the action bar header's: the pane and the header both start `ShellMetrics.sideCardInset` below the
window's top, and the tracker root ignores the safe area (`.ignoresSafeArea()`) as the header does, because under the window's
full-size-content titlebar the hosting view gets a 12pt top safe area that pushed the banner 12pt below the header
(`testTrackerBannerStaysLevelWithTheHeaderUnderTheTitlebar`; the headless renders have no titlebar and cannot show it).
It has no keys and no hover look, does not scroll with the plates or dim with a dropped connection, and goes with the pane when
the tracker hides. The frame is the action bar header's scooped panel (`scoopedPanel`, `ActionBarMetrics.scoopRadius`, raised
elevation, the panel fill and `lineSoftSubtle` border), not the SVG's own frame; the SVG is 354 wide, wider than the 280 column,
so the wordmark keeps the SVG's scale (109 wide) and sits centred, shifted `TrackerHeaderMetrics.svgShift` (-37) into the
narrower frame. It is drawn as the SVG's own path data (`TrackerHeaderArt`; the SVG is kept in
`app/Tests/QuestmasterLogicTests/Fixtures/tracker-header.svg`) in a `Canvas`: flat emblem fills from the `AppPalette.wordmark*` inks,
and the letters' angular gradient as a squashed conic gradient clipped to the letters (CoreSVG cannot draw it). The first plate
section starts at `TrackerListMetrics.firstSectionTopInset` (`Space.section`, 20) below the banner, inside the plates' list, as does the
loading skeleton, so the plates' visible top is `headerHeight` + 20 below the pane's top; no project header is drawn above it, and
the silhouette margin is only in its layers. Under the list,
`TrackerListMetrics.avatarClearance` (`Space.group`) precedes the fixed avatar slot. Its sole stands
`TrackerListMetrics.avatarBannerGap` (`Space.item`, 10) above the session banner's id tab: the gap sits below the slot, so
the slot keeps its size, every pose moves up with it, and the plate list gives up the room. The slot and banner are 280pt wide (the plates and the PR badge column, `TrackerListMetrics.columnWidth`), left-aligned with the master plates at
`TrackerListMetrics.sidePadding`; the slot reserves the tallest bundled class's idle figure, rounded up to 5pt (175pt now),
so changing classes never moves the layout. `Space.section` separates the banner's bottom from the shells. With no
shells, the banner ends `verticalPadding` above the column's bottom. Only an attached plate (master or worker) reserves
the avatar slot and banner. With a shell, tmux or orphan attached, or no known attachment, both disappear and the plates
use their space, ending `Space.section` above the shells or `verticalPadding` above the bottom. The tracker has one cursor id; the plates'
list and the shell section each receive it only for their own rows, and a cursor the pointer moved scrolls neither
(`PointerCursor`).

The session banner (`SelectedSessionTag`) carries the attached session's id, title and project below its class sprite.
Its id tab is inset `Space.row` on each side, its title truncates, and its project bar uses the project's colour.
Every attached plate shows its own title, id and project, including a class without art; its avatar slot stays reserved
when no sprite is available. The banner resolver (`SelectedSessionTagContent.make`) returns no content for shell rows,
nothing attached or an unknown id, so neither banner nor avatar slot appears. A click copies the attached id. The sprite
draws over the list; the banner draws in front of the sprite, keeping its raised shadow; art hanging below the sole shows in the gap.
`SelectedSessionPanel` remains for its standalone previews and self-tests. An attached worker's slot draws its master's class's familiar
in the same slot and above the same banner (`.agents/skills/class-avatar/SKILL.md`); its size and place never change for a worker. An
attached master's slot also holds its live workers' familiars in front of it, small, in one row (a designed row: beside the master while the pair fits, else from 10pt; or the fit rule's row anchored at the slot's right), with a `+n`
chip above the master's familiar's disc once the row is full (`TrackerCompanySlot`, `TrackerCompanyStage`). The master moves left as the row
grows; the slot, banner and plate list stay put.

Master plates are `TrackerPlateDesign.plateWidth` (240pt). Worker discs keep their 20-60pt column and their plates
and cast bars end flush with the masters at x240; only straight SVG runs shorten, so portraits, corners and borders
keep their shapes. The retained standalone selected-session panel uses the same width. The tracker content reserves
`TrackerListMetrics.contentWidth` (282pt), plus its 20pt leading gutter: the plate column, a permanent 40pt badge column
(5pt gap and 35pt chip), and the existing 2pt band allowance. No watches leaves that column empty; its width never jumps.

Only master plates show PR chips. The stack starts at the top of the plate's project tab (`TrackerPRBadgeMetrics.topInset`,
an offset that leaves the group's reserved height alone), not the disc's top, and stacks a merge-conflicts chip first
(the Watcher's red X ring; a conflicting open or draft PR counts there only), then open, draft, merged, closed in
order, skipping zero states. `TrackerPullRequestBadge` in Core supplies the chips from snapshot totals; the daemon counts
the same live master-and-workers watch scope as the Watcher revision, counting shared PRs once. Unknown states contribute
nothing, and ending a watch removes its contribution with no retention. The chips reuse the Watcher's git glyphs and
colours (green, grey dashed, purple, red). `TrackerPRBadgeMetrics` sets their 35x20pt size and 10pt icon; each chip casts the shared `Elevation.raised` shadow, like the plates; gaps and horizontal
padding are `Space.row`, corners are `Token.Radius.segment`. Counts 1-9 use the normal font; above 9 the label is a single
`+`, with no font shrinking. Every chip's tooltip gives its exact count. Chips have no click action. A chip appears and disappears like an
expanded worker's plate, sliding from the top and fading over `MotionStep.standard` (skipped under Reduce Motion); chips are
keyed by state, so a count change keeps its chip in place. A master group's
height is the maximum of its plate content (including casts, collapsed circles or expanded workers) and its chip stack.
A fitting stack adds no height; a taller stack reserves room before the next master, so adjacent four-state masters
cannot overlap. The 240pt plate holds six collapsed worker circles, previously seven at 260pt: circles stay 25pt with
5pt gaps and start at x40, so seven would reach x245, beyond the new plate edge.
