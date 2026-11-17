# Dock and action bar

- Watcher and Worker Log start open in the first window layout, while startup resolves its session; no opening
  transition runs before the window appears. After startup, both panels hide if no session is attached, keeping their state.
- Dock titles (Artifacts, Worker Log, Watcher, an open artifact) are `PanelTitle`, the one title every dock and modal uses:
  title case in `accent`, 14pt bold (`AppFonts.panelTitle`), centred in the top bar. The bar is 40 high (`ShellMetrics.dockTopBarHeight`)
  and its icons centre 20 down. The title's baseline is derived, not set: its text frame ends `Space.item` above the
  bar's bottom edge (`PanelHeaderMetrics.titleBaseline`, 25.8 in JetBrains Mono 14). Everything under the title is the
  shared header rhythm (`SharedUI/PanelHeader.swift`): an element under the title sits on the bar's bottom edge, 10
  under the text frame; the panel's content sits 20 under its last element, or 10 under the bar when only the title is
  over it (`PanelHeaderMetrics.bodyTopInset`). An open artifact's title sits between its back arrow and its actions, and a long one truncates at the tail. The bar
  ignores the titlebar's safe area, so the top dock's title sits where it does with no titlebar
  (`testDockTitlesStayCentredInTheirBarUnderATitlebar`). While a refresh the user asked for (`r`) is under way, Watcher's
  bar shows the working spinner (`SpinnerRingView`, `WorkingSpinner.period`) on the icon line, `Space.item` past the
  title's end, a chip's size; the title stays put. Core decides it (`PullRequestStore.isRefreshing`): from the key to the
  daemon's reply (`pr.refresh` with `wait`), for at least one turn and never past 30s; a second `r` meanwhile sends
  nothing, and the daemon's background polls never show it. It is Core Animation only, runs only while on screen, and
  holds still and full under Reduce Motion. When the refresh ends the spinner goes. No hint or footer text.
- The action bar is a header over the terminal column (`Main Chat Header.svg`): a scooped
  panel (`ActionBarMetrics.height`, `scoopRadius`), its top level with the tracker's and the dock's (`sideCardInset` down), `Space.section` from the
  tracker's plates and the dock, or from the window's edges when they're hidden, with the terminal's text starting
  `Space.section` under it. `ShellSplitLayoutPlanner` gives its frame (`headerFrame`) and `MainSplitView` lays it out
  and animates it with the panes. Its buttons sit centred (`ActionBarMetrics.buttonSize`, `buttonInset`) and `endInset` in from
  its ends: the tracker toggle alone at the leading end; New Session, Quest Log, New Quest (opens the same modal as ⌘T)
  and Settings, then Artifacts, Worker Log and Watcher at the trailing end, `buttonSeam` apart in a group and `groupGap`
  between the groups; caffeinate `toggleGap` past them. Its glyphs are `AppIcon`s, 25pt (`ActionBarMetrics.iconSide`). A raised button (its look is active or
  on: the tracker shown, a dock panel shown, caffeinate on) is an `item` tile with a `line` border and draws the filled drawing;
  a recessed one is a `well` tile with a `lineSoftSubtle` border and the line drawing. The caffeinate toggle's icon is the one
  gold (`accent`) while it is on, and it takes the on look (`OnLook`: the brass glow inside its border, with the working spinner turning round it). Under the pointer the border steps up one rung, and a recessed button's icon lights to
  `textSelected`; the states are in `interaction-states.md`.
  Its empty space drags the window. Toasts sit `Space.section` above the
  window's bottom edge.
- Scoops are stepped (`ScoopedRectangle`): a 5pt square step at each end of the scoop, its arc centred on the step's inner
  corner. The action bar header and the tracker banner step 3 at their 13pt scoop (`ActionBarMetrics.scoopStep`); the
  cards keep the plain scoop. The artifact column has no inset of its own: its filter and rows sit `PanelMetrics.contentInset`
  (20) in on both sides, and a row's delete-mark gutter is the leading one, so the marks sit in the panel's margin. The list
  ends one margin above the bottom edge, where the bottom corners' scoop reaches the margin, so its last card clears the scoop.
  The toast is a scooped panel too, with its own size (`ToastBanner.scoopRadius` 10, `scoopStep` 2: the action bar's proportion for a one-line toast).
- The Artifacts' Session/All tabs are text tabs (`TextTabRow`, as the Worker Log's and the Quest Log's), the first thing in
  the header (`ArtifactDockView.artifactSelector`). The row is centred on the panel and sits on the top bar's bottom edge,
  `Space.item` (10) under the title's text frame (`PanelHeaderMetrics.elementGap`); its box is `TextTabMetrics.height`
  (25), with the label's baseline 17 down, and each diamond sits `TextTabMetrics.separatorGap` (`Space.item`, 10) from the
  tabs either side. The filter (All only) sits `Space.item` (10) under the tabs, and the first card sits
  `PanelHeaderMetrics.contentGap` (`Space.section`, 20) under the filter, or under the tabs in Session. A narrow
  dock scrolls its tabs sideways with fades, as the Worker Log's do. The mock draws the filter under Session too; the dock
  shows it under All only (the user's decision).
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
