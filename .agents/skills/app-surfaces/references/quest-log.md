# Quest Log

- **The Quest Log's list** is one flat list, newest created first (ties by id), not grouped by project
  (`QuestDisplayState.visibleQuests`). Project tabs (`TextTabRow`, the Worker Log's text tabs) sit above the filter,
  centred over the column while they fit and scrolling sideways past it: All, then one tab per project that has quests,
  in the Settings project order; quests without a project show only under All. `[` and `]` step the tabs. The selected tab lives in `QuestLogStore` and survives closing the log; it falls
  back to All when its project has no quests left. The filter takes free text plus `@type:` and `@size:` tokens
  (`QuestListFilter`): any selected tag within a group matches, and the text, the tags and the tab must all match.
  Every row is a scooped card at `ListItemMetrics.height`, including untagged quests. It shows its title, then its tag
  chips (size first, then types in `QuestTags` order) on the left and the project name on the right in the project's
  colour, or the row's meta colour without one. Tags stay on one line and clip within their share of the row; the full
  set is in their tooltip. The project name truncates when needed. A quest without a project says "No project".
- **The left column has one gutter.** `QuestLogMetrics.columnGutter` (`Space.section`) is the room left of the leading edge
  that the project tabs, the filter and the cards share (`QuestLogLayout.columnLeadingX`). The tabs and the filter are
  one gutter in; the list's scroll view starts at the column's outer edge and pads its cards by the same gutter, so the
  scroll clip holds the gutter. The trailing edges of all three stay flush with the column's right edge.
- **The selected quest is the keyboard cursor.** Its card keeps its fill and bold title and draws the menu pointer in
  that gutter, outside the card's leading edge (`RowLook.cardLasting`), not an outline. The pointer hangs alone to the
  left of the tabs, the filter and the cards.
- **The Quest Log's size** is fixed at `QuestLogMetrics.sheetSize`. A smaller window shrinks the modal through
  the shared fit in `ModalScaleView`, as other modals do. `QuestLogLayout` places the parts: the page keeps its proportions
  and takes the height, the left column takes the width.
