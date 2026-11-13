# Shadows, shared components and look rules

- Bold means selected and appears only in a lasting-selection list, a text tab row's selected tab or a selection chip's value. Artifacts
  have no selected state: picking one opens it.
- Dividers inside rows are `line` in every state.
- Brass and glow mean "on", for toggles only. One gold, `accent` #D7B13D, for
  titles, project headers and marks; never for selection or focus.
- Shadows come only from an elevation token (`Elevation` in `SharedUI/Theme.swift`), never numbers at the call site;
  each is a black drop shadow, and a shadow drawn inside a clip is a bug (draw it outside, as `scoopedPanel` and
  `ScoopedLayerChrome` do). The look stays flat, so everything at panel level takes the one tight shadow, `raised`
  (black 35%, blur 4, 1.5 down): tracker plates and their discs, every dropdown (`SuggestionDropdown`), the dock's
  panels, the action bar header and the toast; there is no softer panel level. A layer that draws a shadow leaves
  `raised.bleed` (7.5) of room past its shape (the plates' `TrackerPlateDesign.silhouetteMargin` and the toast's
  `ToastBanner.shadowMargin` are 10). `modal` (45%, blur 30, 10 down): every in-window modal, the Quest Log included. An inner shadow, the one kind that belongs inside
  its clip, is a `Recess` token in the same file (`portrait`: 3 deep, blur 1, black 20%, the sheets' portrait discs).
  Panel, dock and toast borders are 2pt
  `lineSoftSubtle` (`ScoopedRectangle.borderWidth`). A dock panel's frame lifts to
  `controlBorder` while it has keyboard focus and no modal is drawn, and only the focused panel's does
  (`OutlineLook.frame`, `ShellFocusCoordinator.updateRegionKeys`). Pressed is
  0.8 opacity; disabled is window fill with `item` border and label (the shared
  button styles).
- Use the shared components: `stateRow` for rows (`ListRow` for the tracker's
  plates), `PillTab`/`PillTabRow` for tabs (no icon: no disc),
  `fieldChrome`/`FormTextField` for fields, `FilterBar` for filter fields,
  `SuggestionDropdown` for every dropdown and suggestion list (`dropdownChrome`
  is its box, for a dropdown that isn't a list of suggestions), `FilterChip` for
  filter chips (`ClearableChip` for a selection with an x), the `AngledButton`
  styles for buttons.
