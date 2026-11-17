# Dock and action bar

- Watcher and Worker Log start open in the first window layout, while startup resolves its session; no opening
  transition runs before the window appears. After startup, both panels hide if no session is attached, keeping their state.
- Dock titles (Artifacts, Worker Log, Watcher, an open artifact) are title case in `accent`, 14pt bold, on a title plate
  (`DockTitlePlateView`) whose centre sits on the panel's top border's centre line: 30 high (`DockTitlePlateMetrics.height`),
  rising `lift` (14, derived as `height / 2 - ScoopedRectangle.borderWidth / 2`) above the panel's edge, `Space.section`
  either side of the title, and ending in `AngledButtonShape`, the angled buttons' own ends. Its
  2pt border is the dock's frame look: `lineSoftSubtle`, lifting to `controlBorder` while the dock has the keys
  (`OutlineLook.frame(focused:)`). The plate hides the panel's border behind its fill, and the top bar keeps only the
  icons (and, on the Artifacts list, the Session/All tabs). The dock gap stays `DockColumnLayout.panelGap` (20): the lower plate's top sits 6 below the panel above's bottom
  edge, which is also its border's nearest edge. The top dock's plate top sits 6 below the window's top edge. While a
  refresh the user asked for (`r`) is under way, Watcher's plate takes the on look (`OnLook`, the caffeinate toggle's own
  effect): the brass glow band inside its border at 15% (`Token.Size.glowRing` past the 2pt border), and the tracker's
  working spinner (`SpinnerRing`, `WorkingSpinner.period`) turning round the plate's angled outline (`SpinnerOutline.shape`).
  The plate's title stays where it is and there is no separate spinner. Core decides it (`PullRequestStore.isRefreshing`): from the key to the daemon's reply
  (`pr.refresh` with `wait`), for at least one turn and never past 30s; a second `r` meanwhile sends nothing, and the
  daemon's background polls never show it. It is Core Animation only, runs only while on screen, and holds still and
  full under Reduce Motion. When the refresh ends the plate returns to its rest look. No hint or footer text.
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
  gold (`accent`) while it is on. Under the pointer the border steps up one rung, and a recessed button's icon lights to
  `textSelected`; the states are in `interaction-states.md`.
  Its empty space drags the window. Toasts sit `Space.section` above the
  window's bottom edge.
- Scoops are stepped (`ScoopedRectangle`): a 5pt square step at each end of the scoop, its arc centred on the step's inner
  corner. The action bar header and the tracker banner step 3 at their 13pt scoop (`ActionBarMetrics.scoopStep`); the
  cards keep the plain scoop. The artifact column has no inset of its own: its filter and rows sit `Space.section`
  (`MenuPointerMetrics.gutter`) in on both sides, like the Quest Log and the Watcher (its tabs are in the top bar, below). The row's mark and the keyboard
  pointer draw in that gutter, 3.5pt from the panel's outer edge, 1.5pt clear of its 2pt border. The toast is a scooped panel too, with its own size
  (`ToastBanner.scoopRadius` 10, `scoopStep` 2: the action bar's proportion for a one-line toast).
- The Artifacts' Session/All tabs are text tabs (`TextTabRow`, as the Worker Log's and the Quest Log's) in the list's top
  bar, not in the list (`DockTopBarModel.artifactScope`, set only for the list route, so the viewer, the Worker Log and
  Watcher have none). They sit in the bar's 40pt band, centred between `ArtifactScopeTabsMetrics.sideInset` on each side
  (the bar's inset, the close button's icon and `Space.item`), with the label's baseline on the bar's bottom edge
  (`ArtifactScopeTabsMetrics.top`). The label's top then stands 15 under the title plate's bottom edge, as the mock
  (`artifact-tabs-mock.png`, 3x) has it (14.7, snapped 15). The list starts `Space.section` under the bar's edge, so the
  filter (All only) and the first card sit `Space.section` under the baseline, as the mock has them. The mock draws the
  filter under Session too; the dock shows it under All only (the user's decision).
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
