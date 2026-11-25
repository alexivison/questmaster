---
name: class-avatar
description: For working on the Questmaster codebase itself (not for users of the questmaster CLI). The class avatar - the animated pixel-art figure of the attached master's class standing just above the session banner in the tracker - and a worker's familiar in the same slot: their per-class animation.json and sprite art (Resources/Sprites and Resources/Familiars), poses, cues, the idle (breathing, blink, fidgets, idle effects), the calling-out bubble and the avatar slot. Read before changing any of it or adding a class's art or a familiar's.
---

# Class avatar

The attached master's class stands as an animated sprite just above the session banner at the bottom of the tracker. An attached
worker shows its master's class's familiar in the same slot: the same director and timings, its own poses, and no cues. An attached
master also shows its live workers' familiars, small, to its right (in front of it once the row is full): the master's company, laid out by `TrackerCompanyLayout` (Core)
and drawn by `TrackerCompanySlot` (App). Core decides
what it does (`TrackerAvatarDirector`, `TrackerAvatarPose`, `TrackerAvatarAnimation`, `TrackerAvatarCatalog`, all pure and tested); the App
target draws it (`TrackerAvatar*`). Each class's art is one folder of PNGs plus its `animation.json` in `Resources/Sprites/<class>/`, and each
familiar's in `Resources/Familiars/<class>/`; both are made by a sprite pipeline outside this repo, and the palettes are documented in
`docs/sprites/palettes/`. The familiars come from `~/Documents/Questmaster/Sprites/tools/familiar-ship/` (its converter builds the folders
from the frozen art; rerun it, then copy the PNGs and `animation.json` byte for byte).

| Changing | Read |
|---|---|
| A class's `animation.json`, its art, the idle or the bubble | `references/animation-file.md` |
| A familiar's `animation.json` and art, its pose set, its bubble and size | `references/animation-file.md` (Familiars) |
| Which pose shows when, cues, bows, finishes and enters, the slot, Reduce Motion | `references/behaviour.md` |
| A worker's familiar's poses and which art a worker draws | `references/behaviour.md` (Familiars) |
| The master's company: the row, the `+n` marker, each familiar's size | `references/behaviour.md` (Company) |

Self-tests read every bundled class (decoding, missing frames, feet on the baseline, the slot's height), so a
new or changed class needs its expected values updated in `LogicSelfTests.swift` and `TrackerAvatarAnimationTests.swift`. Every bundled
familiar is read the same way (`testEveryBundledFamiliarFitsTheSlot`: its frames, its bubble, its sole on the baseline, and its figure inside
the slot's width and height), and `TrackerAvatarFamiliarTests.swift` covers its poses and the worker's choice of art.

Recording what a class does, off-screen (DEBUG): `RENDER_ONLY=tracker-avatar-idle-motion` records the selected class's
  authored idle and a forced blink as a class-specific GIF (`AVATAR_CLASS=wizard`, for example). The avatar recordings (`RENDER_ONLY=avatar-report-catch`, `avatar-message-release`, ...; `AVATAR_CLASS=cleric`
  picks the class) record the slot at real speed into `<name>-frames/`.
