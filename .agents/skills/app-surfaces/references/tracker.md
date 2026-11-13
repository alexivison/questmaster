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
A shell row is 35 high (`ControlHeight.field`) and as wide as the 260 column, flush with the plates, stacked with no gap
(the tracker mock's layout, not Shell Session.svg's inset and spaced rows), with a 25pt disc (`ControlHeight.compact`) 10
in and the title 10 past it. The shell section is pinned to the bottom of the tracker column (`verticalPadding` from its
edge), as tall as its rows up to `TrackerShellMetrics.maxHeight` (175, five rows), and scrolls inside itself past that;
the plates scroll in their own list above it. The first plate section starts at
`TrackerListMetrics.firstSectionTopInset` (`ActionBarMetrics.height`, 50), as does the loading skeleton: the first plate's
visible top is level with the action bar header's bottom edge (the pane and the header both start `ShellMetrics.sideCardInset`
below the window's top; no project header is drawn above the plate; the silhouette margin is only in its layers). Under the list,
`TrackerListMetrics.avatarClearance` (`Space.group`) precedes the fixed avatar slot. Its sole stands
`TrackerListMetrics.avatarBannerGap` (`Space.item`, 10) above the session banner's id tab: the gap sits below the slot, so
the slot keeps its size, every pose and the spells' hand point move up with it, and the plate list gives up the room. The slot and banner are 260pt wide and left-aligned with the master plates at
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
`SelectedSessionPanel` remains for its standalone previews and self-tests.
