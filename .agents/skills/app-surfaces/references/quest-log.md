# Quest Log

- `y` copies the selected quest ID or the marked quest IDs in list order.

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
- **Margins.** The tabs, the filter and the cards start `QuestLogMetrics.inset` (`PanelMetrics.contentInset`, 20) in from the
  sheet's left edge, and the page keeps the same inset on the right. The list's indicator is `.never` (`QuestLogList`), so the
  cards keep the column's full width while it scrolls, and their trailing edges line up with the filter's, `columnGap` short of the page.
- **The Quest Log's size** is fixed at `QuestLogMetrics.sheetSize`. A smaller window shrinks the modal through
  the shared fit in `ModalScaleView`, as other modals do. `QuestLogLayout` places the parts: the page keeps its proportions
  and takes the height, the left column takes the width.

- **Attachments.** New Quest and Edit Quest place a 150pt dashed drop area above the body text, with the image
  glyph, “Drag and Drop or Choose a File” and filename chips directly beneath it, wrapping onto further rows
  within the form's width. Long filenames truncate in the middle and keep their path tooltip. The body retains
  a minimum editor height; when many chip rows exceed the modal, the form scrolls vertically above its buttons.
  Choose a File and ⇧⌘A open
  the file picker; local file/image drops use the same draft. The chips have no kind label or divider, and their
  x removes an existing or pending file. Saving copies regular files into the private quest library (up to 20
  per quest, 25 MiB each). New Quest is 540 × 620; Edit Quest is 450 × 690 with 150pt Cancel/Save buttons.
- **Page attachments and dates.** Saved attachments appear in a wrapping grid of 65pt tiles beneath the
  description. Images use bounded thumbnails; other files and unavailable previews show their filenames.
  Clicking a tile opens the stored copy in its default application. The dates stay at the foot of the parchment
  while the body and tiles scroll above them; the project's name remains on the quest card. The Quest Log is
  900 × 780. Removing an attachment or deleting its quest removes the copy, leaving the original alone.

- **Attachment keys.** The New/Edit form's attachment area is a field between size (or project on New Quest) and
  the body. Tab/⇧Tab and ⌃J/⌃K reach it; h/l and ←/→ cycle Choose a File and the chips. Return chooses or opens
  the focused file; d or Delete removes that chip from the draft. ⌘Return still saves from the area. A received
  file takes the cursor and is brought into view. Returning to this field from another field focuses the drop
  box, so Return can choose another file without stepping back through existing chips. Hover never moves the cursor.
- **Quest Log file focus.** l/→ (also ⇧⌘L) enters the selected quest's thumbnails; h/l steps files, h before the first
  file or Esc returns to the list, and j/k resumes quest movement. Return/o opens the focused file. d or Delete
  confirms removing that file's stored copy. After its final file is removed, the file area keeps focus until the
  user leaves, so another d cannot become quest deletion. The cursor survives refreshes on an adjacent file.
- **Native drops.** The quest drop target is an AppKit hosting view registered for file URLs and file promises
  (including the screenshot-thumbnail overlay). It accepts drops only for the top quest form. The terminal
  rejects file drops while any modal is drawn and checks again before inserting asynchronously received paths.
  Promised files use private temporary directories, at most 20 files per drop and two receive operations at a time,
  with a 30-second timeout. Save waits for receipt. The draft retains these files through the save acknowledgement;
  removing the final referenced file or cancelling the form releases the temporary copy.
