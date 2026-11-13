---
name: app-surfaces
description: For working on the Questmaster codebase itself (not for users of the questmaster CLI). Decided behaviour and layout of a specific Questmaster app surface - the tracker (plates, shell section, attached dot), the Worker Log and its filter and tabs, the Watcher dock, the dock column, the action bar header, or the Quest Log. Read before editing or adding to one of these surfaces; it records what is app-wide versus per-master, what hides when, and which view owns the keys.
---

# Questmaster app surfaces

These references record decisions the code alone does not explain. Numbers that a `*Metrics` or `*Layout` constant already carries are cited by constant, not restated: read the constant. When a reference and the live code disagree, trust the code. The cross-surface rules (state looks, spacing, motion, modal keys) are in `app-ui`.

| Editing | Read |
|---|---|
| Tracker plates, the shell rows, the attached dot, portraits, the avatar slot and session banner | `references/tracker.md` |
| The Worker Log, its Action filter, its worker tabs | `references/worker-log.md` |
| The Watcher dock and its pull-request rows | `references/watcher.md` |
| The dock column, dock titles, the action bar header, startup layout, dock keys | `references/dock-and-action-bar.md` |
| The Quest Log's list, tabs, filter and size | `references/quest-log.md` |

Shared facts:

- Dock state (which panels show) is app-wide; only the panels' contents follow the attached session.
- The Action ticks are app-wide; the Worker Log's worker tab is kept per master.
- An empty list is one `EmptyState` icon (see `.agents/skills/app-ui/references/empty-loading-states.md`).
