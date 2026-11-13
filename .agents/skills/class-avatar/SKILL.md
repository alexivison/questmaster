---
name: class-avatar
description: For working on the Questmaster codebase itself (not for users of the questmaster CLI). The class avatar - the animated pixel-art figure of the attached master's class standing on the session banner in the tracker - its per-class animation.json and sprite art, poses, cues, spell flights to the Worker Log, the idle (breathing, blink, fidgets, idle effects), the calling-out bubble and the avatar slot. Read before changing any of it or adding a class's art.
---

# Class avatar

The attached master's class stands as an animated sprite on the session banner at the bottom of the tracker. Core decides
what it does (`TrackerAvatarDirector`, `TrackerAvatarPose`, `TrackerAvatarAnimation`, all pure and tested); the App target
draws it (`TrackerAvatar*`, `TrackerFlightOverlay`). Each class's art and timings are one folder of PNGs plus its
`animation.json`, made by a sprite pipeline outside this repo; the palettes are documented in `docs/sprites/palettes/`.

| Changing | Read |
|---|---|
| A class's `animation.json`, its art, the idle, the bubble or spell frames | `references/animation-file.md` |
| Which pose shows when, cues, bows, finishes and enters, flights, the slot, Reduce Motion | `references/behaviour.md` |

Self-tests read every bundled class (decoding, missing frames, feet on the baseline, the slot's height, spell facing), so a
new or changed class needs its expected values updated in `LogicSelfTests.swift` and `TrackerAvatarAnimationTests.swift`.

Recording what a class does, off-screen (DEBUG): `RENDER_ONLY=tracker-avatar-idle-motion` records the selected class's
  authored idle and a forced blink as a class-specific GIF (`AVATAR_CLASS=wizard`, for example). The avatar recordings (`RENDER_ONLY=avatar-report-catch`, `avatar-message-release`, ...; `AVATAR_CLASS=cleric`
  picks the class) record at real speed into `<name>-frames/`; the two column ones draw the spells flying over the tracker column
  to a stand-in Worker Log panel on its right (`TrackerFlightOverlay`), so a class's flight and impact frames show.
