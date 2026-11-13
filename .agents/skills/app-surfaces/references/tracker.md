# Tracker

- The attached dot follows the attached session, never the cursor or the pointer. A master's or an expanded worker's own
  plate carries it; a worker shown only as a collapsed circle puts it on its master's plate; a shell carries none (its
  filled, bold row marks it), and neither does nothing attached. It sits in the list's leading gutter (a master's reaches
  12.5 left of its row), drawn outside the plate's silhouette layers, which clip at their margin.
- Shells are not plates: every shell, tmux and orphan row leaves its repo group for the shell section pinned under all
  the plates (`TrackerShellSection`, drawn by `TrackerShellRow`). A shell's own display colour tints its title in every
  state; none leaves the state's text colour.

Spacing of the tracker's portraits and shell section (the general scale is `.agents/skills/app-ui/references/spacing.md`). Portraits sit on 5s too: the master's disc spans 0-50 and the worker's 20-60 in
their rows, and plate text starts `Space.row` past the disc's round edge (55,
65; the side diamonds don't count). The selected-session panel's text starts
`Space.item` past its disc (80). Logos are 0.6 of their disc (30, 24, 15),
canvases and icon, logo and mark sizes are lengths like any other. A plate disc with a class portrait carries its
agent's logo in a 25pt badge (logo 15), as big as a collapsed worker's circle, whose edge hangs `Space.row` outside the
disc on the left and below it (`TrackerPlateDesign.badgeOverhang`); the sheets' title row is a 40pt portrait disc, `Space.item`, then the 35pt field.
A shell row is 35 high (`ControlHeight.field`) and as wide as the 260 column, flush with the plates, stacked with no gap
(the tracker mock's layout, not Shell Session.svg's inset and spaced rows), with a 25pt disc (`ControlHeight.compact`) 10
in and the title 10 past it. The shell section is pinned to the bottom of the tracker column (`verticalPadding` from its
edge), as tall as its rows up to `TrackerShellMetrics.maxHeight` (175, five rows) and scrolling inside itself past that;
the plates scroll in their own list in the space above it, which shrinks to make room and ends
`TrackerListMetrics.shellClearance` (`Space.group`) over the section. Each scroller sees only its own rows' cursor
(`plateCursorID` / `shellCursorID`), and a cursor the pointer moved scrolls neither (`PointerCursor`).

