# Modal keys

**Modal keys.** Every in-window modal takes its keys the same way: its focused field's own keys first (a picker's, the
path's, the prompt's), then `ModalKeys.command` (`Core/Navigation/ModalKeys.swift`). A sheet states whether it has text
fields (`ModalKeyContext.hasTextFields`), and the focused part decides the rest:

- **A form with text fields** (New Session, Settings' Models, Add or Edit Project, the tracker's edit sheets, New Quest): Tab, ⇧Tab, ⌃J and
  ⌃K move between its fields, from a select too, so a form never gets stuck. j and k type. The prompt keeps Tab as text.
- **A list or a select-only modal** (the Projects list, the Quest Log's list, a delete confirmation,
  Edit Repo's colour): j and k move its rows or fields. Tab, ⇧Tab, ⌃J and ⌃K take the press and do nothing, so it never
  reaches the terminal.
- **Arrows**: ↑ and ↓ never move a modal. A suggestion dropdown takes them first (`suggestionUp` and `suggestionDown`),
  a text field's caret takes them, and anywhere else they are taken and do nothing.
- **Unchanged**: ⇧⌘J and ⇧⌘K move in every modal; ←/→ and h/l cycle a select; ⇧⌘H and ⇧⌘L as before; Return and Esc as
  before. Settings' own keys (H/L, [ and ], e, R, n, K and J) stay outside a model or reasoning search; printable
  keys in those searches type, and Tab or Return picks a suggestion. ⌥k is no field key.
- **Settings' model and reasoning pickers**: printable keys, including h/l and j/k, start a search. ←/→ cycle in
  SELECT; Esc or leaving the field discards the query without changing its default.
- **The Quest Log** applies the rule per focused part: its filter is a text field, its list is a list
  (`ListCapabilities.modalMoves`). With no suggestion showing, the filter's ↑/↓ are the caret's (`FilterFieldKey`'s
  `arrowsMoveList` is off there), while ⌃p and ⌃n still move the list, as vim's previous and next do.

Non-modal lists (the tracker, the dock's lists, Watcher, the Worker Log) keep their own keys, arrows included
(`ListKeyResolver`'s `moveUp` and `moveDown`).


The quest form's attachment area is a select in the field order: h/l or ←/→ moves between Choose a File and its
chips, Return chooses or opens the cursor's file, and d/Delete removes the chip. Entering the attachment field from
another field returns to Choose a File. The chips wrap into rows; h/l follows their file order across rows.
⌘Return submits. In the Quest Log,
l/→ enters the file area, h/l traverses it, Return/o opens a file, and d/Delete asks to remove it. Esc returns to the
quest list first; j/k resumes quest movement. The normal modal Tab and vertical-arrow rules remain in force.
