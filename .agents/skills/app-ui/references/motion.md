# Motion

Every one-shot transition takes a step from the motion tokens, so the app moves at two paces on one easing. A view never
states a duration or a curve. Core holds the numbers (`MotionStep`, `MotionEasing` in `Core/Rendering/Motion.swift`), the
App target the forms each framework takes (`Motion` in `SharedUI/DesignTokens.swift`).

| Step | Seconds | Role |
|---|---|---|
| `MotionStep.fast` | 0.12 | a small change: the modals' fade-out, the toast showing, a page swap or overflow cue in the Quest Log, the artifact rows' select-mode toggle, the cast bar's fade, a modal's scale back on close |
| `MotionStep.standard` | 0.18 | a panel, modal or layout move: the modals' fade-in and scale-in, the toast hiding, the split view's panes, the dock's panels (`DockPanelMotion`), the tracker's expand/collapse and cast-row open/close, the Quest Log's unroll, the worker chat's glide and arrival fade, the attach veil, the selected-session panel's icon fade, the status ring's crossfade, exit sweep, flash and exit fade, the cast bar's finish flash |

- **One easing:** ease out, quick at first and settling, as the cubic Bézier (0, 0, 0.58, 1), the system's own `.easeOut`.
  `Motion.timingFunction` is its Core Animation and AppKit form, `Motion.animation(_:after:)` its SwiftUI form, and
  `MotionEasing.eased` the same curve for a transition stepped by hand (the dock column).
- **One breathing easing**, for a continuous animation that eases up and back (the cast bar's and the status ring's
  pulse): ease in and out, the Bézier (0.42, 0, 0.58, 1), the system's `.easeInEaseOut`. `Motion.breathingTimingFunction`
  is its Core Animation form (numbers in `MotionEasing.breathingControlPoints`). A one-shot never takes it, and a pulse
  takes no other curve; a new continuous animation (a skeleton's breath) uses it too.
- **Reduce Motion is read once**, in `Motion.reducesMotion` (a var, so a self-test can set it). Under it every step is 0:
  `Motion.animation` returns nil (the change lands at once), `Motion.configure` gives an AppKit context no duration, and
  Core Animation code checks `Motion.reducesMotion()` and adds no animation (a duration of 0 means "the default" there). A
  transition is skipped, not shortened; a fade is skipped too. A Core Animation view that already gets `reduceMotion`
  from the SwiftUI environment (the status ring, the cast bar) skips on that and takes its step lengths from
  `Motion.duration`; the ring's exit and crossfade are skipped under it, so the ring just goes. The logic-test runner
  starts every case with it off.
- **Modal entrance.** Every in-window modal fades in and scales from 0.97 to 1 about its centre over `standard`, and on
  close fades out and scales back over `fast` (`ModalLayer`, then `ModalScaleView`). The fit to the window is the scale
  view's AppKit bounds, so events and text geometry map exactly. The entrance is a Core Animation transform on a child
  view that AppKit never scales: animating the bounds moved a native scroll view's offset during the scale (the Quest
  Log list's first row). While the transform runs, nothing in the modal takes a click; it takes them once it has settled.
- **Sequencing** is a step too: `Motion.animation(.standard, after: .fast)` starts one step late (the Quest Log's paper
  unrolls as the modal's fade-in ends, then the ink follows).
- **One-shot only.** The terminal shares the main thread, so a transition runs once and nothing keeps running. Prefer
  Core Animation; SwiftUI's `withAnimation` and `.animation(_:value:)` are fine for a short one-shot. Continuous
  animations (`SpinnerRing`/`WorkingSpinner`, the cast bar's and status ring's fill, pulse and shimmer, the skeleton
  pulses) keep their own periods, named as a `period` or a duration learned at runtime, and are outside the steps. An
  animation that ends, even one of those views' (a flash, an exit, a crossfade), takes a step.
- **A new transition** picks `fast` or `standard`; a step is added to `MotionStep` only for a new pace the app doesn't have
  yet, never a one-off number.
- **Selected-session panel:** the disc's icon is the class portrait; a shell, tmux or orphan session shows the shell
  row's terminal glyph (`ShellTerminalGlyph`, scaled with the disc, `textMeta`); no class, or nothing attached, leaves the
  disc empty. The icon fades in once when the attached session or its portrait changes, over `standard`; the old icon goes
  at once and the first draw doesn't fade. It is one Core Animation opacity animation (clear to full,
  `Motion.timingFunction`) on the icon's own layer, run by the render server, so SwiftUI redraws nothing for it
  (`IconFade`, a hosting view like `SkeletonPulse`'s; no `.id`/`.transition` re-creation per switch). The disc is drawn in
  layers so only the icon fades: the base (with the strips, one Canvas), the icon's one `IconFade` layer, and the
  overlay (a Canvas). The icon key is empty when the disc has none, and an empty key never fades, so a switch fades only
  an icon coming in: one fade a switch that brings an icon in (from an empty disc too), none to an empty disc. A change
  with no window or the same key adds no fade; a new key (an empty one too), leaving the window, or any update under
  Reduce Motion drops one still running.

`MotionRulesScanTests` (in the logic-test runner) scans `app/Sources/App` and fails on a break:

- **raw-duration**: a number literal as an animation's `duration:` / `.duration =` / `.delay(` /
  `setAnimationDuration(` (0 is allowed), or a SwiftUI curve built outside the token layer (`.easeOut`, `.snappy`,
  `.spring`, `.default` … in `withAnimation`, `.animation` or an `Animation` value; they carry a default duration of
  their own); a repeating SwiftUI animation is no exception.
- **duration-constant**: a constant or local whose name ends in a timing word (duration, delay, time, fade, crossfade,
  sweep, flash, transition, glide, unroll) assigned a non-zero literal, typed or inferred (`let fadeTime = 0.4`); it
  comes from a step. A continuous animation names its `period`.
- **raw-easing**: any `CAMediaTimingFunction(` (by name or control points) or `.timingCurve(` outside the token layer.
  A one-shot takes `Motion.timingFunction`, a pulse `Motion.breathingTimingFunction`. There is no exception by file or by
  neighbouring line, and no file list: a finite animation and a continuous one are held to the same three rules, and a
  continuous one passes them by naming its `period` and taking the breathing token.

The scan reads lines, so a duration passed through a helper's parameter isn't seen.

`testSelectedSessionPanelFadesItsIconInWhenTheSessionChanges` (`LogicSelfTests.swift`) documents what it asserts in its own doc comment. To record that fade frame by frame:
`RENDER_ONLY=selected-session-fade-gif QUESTMASTER_ANIMATION_SLOWDOWN=6 … --render-preview <dir>` (`QUESTMASTER_ANIMATION_SLOWDOWN` stretches every step in DEBUG builds so the recorder can sample it).
