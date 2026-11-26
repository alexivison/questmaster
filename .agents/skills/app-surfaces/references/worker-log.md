# Worker Log

- The Worker Log's filter (`WorkerLogFilterPanel`) is a dropdown of the Action
  checkbox rows on `dropdownChrome(.raised)`: it stands in front of the dock, so it is
  lighter than it (`item` fill, `line` border, radius 4.5), and its rows take the
  raised looks (`RowLook.raisedPick`). A checked box's mark takes the row's text
  colour. Ticking every box is an ordinary selection (the chip names all five
  and only its x clears it). The Action ticks are app-wide: one selection shared by
  every master, kept when the attached master changes (`WorkerChatStore`, in
  memory only, so not across restarts). The dropdown is as tall as its rows, up to the panel's height less the room under the bar and the
  bottom reserve (`WorkerChatMetrics.inset`, or `WorkerLogTabMetrics.reserved` when the tab row shows), and scrolls past that with the
  cursor kept in view: with Watcher above, the bottom panel is shorter
  and it scrolls sooner, never reaching behind it. The filter belongs to the
  bottom panel: its icon sits in that panel's top bar, shows only while the log
  is attached to a master and toggles the dropdown; `f` and the dropdown's keys
  work only while that panel has the keys, and the keys leaving it (to Watcher, the tracker, the terminal or a modal) close it. A click anywhere else
  on the dock, either top bar included, closes it too. Its one chip reads "Action:" in
  `textMetaHighlighted` at regular weight, then the ticked names in `textBody` **bold** (the
  current selection is what bold means), comma-separated in the dropdown's order, which is
  alphabetical (Cast, Item, Message, Status, Summon; `WorkerLogAction`, `WorkerLogFilter.actionSummary`), and grows with them; with nothing attached the log is
  blank, chip included. It sits on the top bar's bottom edge, `Space.item` under the title (`PanelHeaderMetrics`), and
  stays there whatever the feed is doing (first read pending or failed, empty, lines). The feed fades in under its header,
  the bar and the chip when there is one, over its `topInset` (the Quest Log's overflow mask), so lines scrolled up under
  it are never cut hard. A feed's first line sits `PanelHeaderMetrics.contentGap` (20) under the chip, or
  `PanelHeaderMetrics.bodyTopInset` (10) under the bar with no chip, and the fade covers that band.
- The Worker Log's worker tabs (`WorkerLogTabRow`, from `Tabs (Simple).svg`) are pinned to the bottom of the panel: All, then
  one text tab per worker of the attached master in tracker order (`WorkerChatStore.workers`), the feed's chat
  font (`AppFonts.workerTab`), a diamond (the `line` colour) between them (`TextTabMetrics.separatorGap` on each side). They take a `TextTabLook`. One tab is
  selected (`WorkerLogFilter.workerID`, nil for All): All shows every worker's lines, a worker's tab only that worker's,
  and it ANDs with the Action ticks. The tab is kept per master (it names that master's workers; in memory only), unlike
  the Action ticks, and falls back to All when its worker goes away. Hidden while the master has fewer than two workers (All plus one tab adds nothing;
  `WorkerChatStore.showsTabs` is the one predicate for the view, the dropdown's room and the keys), and when the row
  goes away the selection falls back to All, a remembered tab included. A click selects a tab; `[` and `]` step to the previous
  and next, wrapping as the Settings tabs do (`Keymap.Action.previousTab` and `nextTab`, handled where `f` is), with the dropdown open or closed,
  and work only while the bottom panel has the keys and the row shows (otherwise they pass through). The feed ends where
  the row begins; the row's height, baseline and bottom inset are `TextTabMetrics` and `WorkerLogTabMetrics` (`reserved`,
  `bottomInset`). Tabs too many for the
  panel scroll sideways with no scroller, in a view inset by `WorkerLogTabMetrics.sideInset` (the bottom corners' scoop
  radius plus `Space.item`, 35, a scoop exception to `PanelMetrics.contentInset`): the scoop reaches about 25 in along the
  row's bottom edge, so every tab, clipped or not, stays 10 clear of it; a side
  with hidden tabs fades out over `TextTabMetrics.fadeWidth`, as the feed's top does. A change of selection scrolls it to the middle. The empty state stays centred in the room above the row.
- With the Worker Log focused and its Action dropdown closed, Return or keypad Enter attaches the selected worker tab's
  session and focuses the terminal, using the tracker's activation path (including continue for a stopped session).
  All has no attachment target. With the dropdown open, Return still ticks its Action row. `⇧⌘U` (Session → Return to
  Master), or the floating Return To Master button centred beneath the chat header, attaches the current worker's master
  from any region; the shortcut is disabled without an existing master and while a
  modal is open. Returning restores that master's selected worker tab and the app-wide Action ticks. A return from a worker
  opened through the Worker Log also moves the keys back to the log when it is still visible.
  The button enters from above with a fade and leaves the same way, like expanding and collapsing tracker workers,
  over `MotionStep.standard`; startup and Reduce Motion skip the transition.
