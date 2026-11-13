# Empty, loading and connection states

- Nothing to list is one icon, `EmptyState`: a single `Token.Size.emptyIcon` (40) tray in `textMeta`, centred in the
  section the list would fill, with no text, hint or command. Every dock panel (the artifact list under its tabs, the
  artifact viewer, the Worker Log, Watcher), the tracker and the Quest Log's page draw it; the page passes the
  parchment ink instead. The Worker Log draws it only once its first read came back whole and empty, or when
  its filter or worker tab hides every line (`WorkerChatStore.isKnownEmpty`, decided in Core; the chip above it stays, with its x, and the tabs under it when they show);
  while that read is pending, failed or partial it is blank, and its `readNotice` says what failed. So does the terminal pane once its session has ended (`TerminalShellView.showEnded`, only
  after the viewed session is deleted with nowhere to switch to); every attach clears it first, and while a session attaches
  the pane shows the skeleton veil. A message the user needs (a missing file, an artifact kind the build can't show, an
  incompatible backend) is a `StatusMessagePane`, which an empty list never is.
- A list still loading is a skeleton: a ghost of the real thing, in its own shapes and palette (the tracker's is
  `TrackerNameplateBackground`'s plates with no text, status or portrait, the Settings picker's is `fieldChrome`, the
  terminal's is `SkeletonBar` lines), breathing in `SkeletonPulse`. That is one Core Animation fade of the layer SwiftUI drew
  the ghost on, `SkeletonMotion.period` (1.6s) each way on `Motion.breathingTimingFunction`, only while in a window, still
  under Reduce Motion (read through `Motion.reducesMotion`, not SwiftUI's environment, so the self-tests' override applies):
  SwiftUI never animates a skeleton, so nothing redraws while the terminal shares the main thread.
- The tracker follows the runtime connection's typed state (`ConnectionState`, on the store's snapshot, decided in Core
  by `ConnectionStateMachine`): its skeleton only while no tracker has come yet (`awaitsFirstTracker`); after a dropped
  connection (every daemon restart) the last tracker stays, drawn at `Token.Opacity.dimmed`, until a fresh one arrives
  (`showsLastTracker`); an incompatible backend empties it and shows its `StatusMessagePane` (`blockingMessage`).
