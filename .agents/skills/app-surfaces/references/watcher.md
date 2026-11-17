# Watcher

- Watcher's rows list the pull requests the attached session watches. Core decides what a row shows
  (`PullRequestDisplayRow`); `WatcherRow` only draws it. The first line is the git state, `#number` and the title. The
  second line is the review glyph, `CI`, the diff counter, then the author and the watchers at the right edge. The review
  glyph is a check ring (approved), an empty amber ring (waiting, or no review yet), a red X ring (changes requested) or
  the grey speech bubble (a commented review, `PullRequestArt.swift`). The author is the login the backend sends, which
  it omits for the viewer's own pull requests, and an inaccessible row shows none. A hairline divider sits between the
  author and the watchers only when both show. One watcher shows its logo and title. Two or more
  show their logos, up to four, overlapping (`WatcherMetrics.stackSpacing`), with `+n` for the rest; the tooltip names every watcher. Under a
  squeeze the watcher title truncates first, then the author, and the counters never truncate. A stale or inaccessible
  row draws its semantic colours in the look's icon colour.

- An open or draft PR with merge conflicts shows the changes-requested ring (the red X ring, `ringChanges` in `gitRed`) in
  its git glyph's place on the first line, as GitHub marks merge conflicts, with the tooltip “Has merge conflicts”. It
  replaces the open or draft glyph and adds no element; a red-tinted git glyph read as the closed one. Core's
  `PullRequestDisplayRow.gitLook` decides whether the icon is normal or conflicting; `WatcherRow` only draws it.
  Closed and merged PRs never show conflicts. Stale and inaccessible rows retain the dimming rule above.
  A watched PR gaining conflicts sends one ordinary `conflicts` event alert, including when first observed on the
  first poll; resolution sends nothing. GitHub's temporary `UNKNOWN` retains the last known conflict value.
- A just-watched PR the daemon hasn't polled yet has no status (`PullRequestDisplayRow.isLoading`, decided in Core). Its row
  is a skeleton until the first poll: ghost bars for the git glyph, the number and the title, then for the review glyph and
  the counters. Nothing real shows, not even the number or the watchers, so the row doesn't fill in piece by piece. The bars breathe
  in `SkeletonPulse` (`WatcherMetrics.skeleton*`). An inaccessible PR has a status and is never loading.
- The keyboard cursor on a row is the menu pointer in the rows' leading gutter, not an outline (`RowLook.pointedCursor`).
  It shows only while the panel has the keys and hides with them, like the cursor's fill. A pointed row takes no hover
  outline; a row that isn't the cursor keeps its hover outline. The rows keep `WatcherMetrics.inset`, which is
  `MenuPointerMetrics.gutter` (`Space.section`), on both sides, so the arrow hangs in the leading gutter clear of the row.
