# Dock and action bar

- Watcher and Worker Log start open in the first window layout, while startup resolves its session; no opening
  transition runs before the window appears. After startup, both panels hide if no session is attached, keeping their state.
- Dock titles (Artifacts, Worker Log, Watcher, an open artifact) are title case in
  `accent`, 14pt bold, on `ShellMetrics.dockTopBarTitleBaseline`. While a refresh the user asked for (`r`) is under way, Watcher's title bar shows the working spinner, the tracker's own (`SpinnerRing`, `WorkingSpinner.period`), as a ring
  (`ShellMetrics.dockTopBarSpinnerSize`) `Space.item` past the title, on the icon line, taking no room so the centred title never moves. Core decides it
  (`PullRequestStore.isRefreshing`): from the key to the daemon's reply (`pr.refresh` with `wait`), for at least one turn
  and never past 30s; a second `r` meanwhile sends nothing, and the daemon's background polls never show it. It is Core
  Animation only, runs only while on screen, and holds still and full under Reduce Motion. No hint or footer text.
- The action bar is a header over the terminal column (`Main Chat Header.svg`): a scooped
  panel (`ActionBarMetrics.height`, `scoopRadius`), its top level with the tracker's and the dock's (`sideCardInset` down), `Space.section` from the
  tracker's plates and the dock, or from the window's edges when they're hidden, with the terminal's text starting
  `Space.section` under it. `ShellSplitLayoutPlanner` gives its frame (`headerFrame`) and `MainSplitView` lays it out
  and animates it with the panes. Its buttons sit centred (`ActionBarMetrics.buttonSize`, `buttonInset`) and `endInset` in from
  its ends: the tracker toggle alone at the leading end; New Session, Quest Log and Settings, then Artifacts, Worker Log
  and Watcher at the trailing end, `buttonSeam` apart in a group and `groupGap` between the groups; caffeinate
  `toggleGap` past them. Its empty space drags the window. Toasts sit `Space.section` above the
  window's bottom edge.
- The dock is two stacked scooped panels, `DockColumnLayout.panelGap` apart: Watcher on top at the fixed
  `DockColumnLayout.watcherHeight`, and
  under it the artifacts or the Worker Log. Each has its own title and close button, and either shows alone
  (it then fills the dock). `DockState` keeps their visibility app-wide; ⇧⌘K and ⇧⌘J move the keys between them (all
  navigation is ⇧⌘). An open modal owns ⇧⌘H/J/K/L: J/K move its vertical cursor or field, and H/L move a horizontal
  choice when it has one; otherwise they do nothing inside the modal. With no modal, H/L focus shell regions and J/K
  are the dock's own only while the dock has the keys and both panels show (`NavigationStore.commandChordRoute`, which
  uses `dockPanelKeyRoute`; pressing the focused panel's key does nothing). From the terminal or tracker, or in a dock
  with one panel, J/K pass through to the focused responder, so Ghostty receives its own ⇧⌘J binding
  (`write_screen_file:paste`); the View menu items are enabled only for the dock route. With no modal, ⇧⌘R toggles
  Watcher from the monitor before the terminal; while a modal is drawn, app shortcuts are consumed or disabled,
  except text editing, Quit and modal commands the top modal accepts (the Quest Log permits its toggle and New Quest as
  a child). A panel appearing or going away fades and slides (`DockPanelMotion.slide`) while the other grows or shrinks, over the standard
  motion step and only once (`DockPanelMotion`; Reduce Motion skips it, see "Motion"): never an animation that keeps
  running, as the terminal shares the main thread.
