# Quests in Questmaster — Build Handoff

You are implementing **Quests inside the existing questmaster repo**. Not a separate binary, not a new tool. You add a quest concept (plan + gates + status), a quest log, quest-aware spawning and attaching, and tracker integration. Build directly into qm.

## Read in this order

1. `01-plan.md` — the design decision record. The what and the why. Read it fully first.
2. `quest-format.md` — the quest file format your parser, validator, and authoring must conform to.
3. `02-tasks.md` — the numbered implementation slices, in order. Your worklist.
4. `quest-ui-mockup.html` — open in a browser. The visual target for the terminal renderer (T2) and the two UI tasks (T9 quests app, T10 tracker line). It shows the detail pane, the list rows, and the tracker quest line. Treat it as the structure and hierarchy target, not a pixel spec: pull the actual palette and keymaps from qm and scry, and remember the real surface is a monospace TUI on one flat background.

This folder supersedes any earlier quests / QMv2 docs in the repo (separate-binary spec, cockpit dashboard mockups, headless plans). If you find those, ignore them. They describe an abandoned design.

## Prime directives (these override convenience)

1. **Build into qm.** No new binary, no new top-level command surface beyond `qm quest ...` subcommands and the quests-app TUI. No instance isolation.
2. **No headless.** Every session is a native TUI in tmux, in view at all times. Do not build a headless supervisor or a rendered session view.
3. **Verifiability is the gate.** `go build ./...`, `go test ./...`, `go vet ./...` green at the end of every task. A task that does not build and pass is not done.
4. **Vertical slices.** Each task leaves the tree compiling and tested.
5. **Quests live in dotfiles.** `~/.questmaster/quests/<id>.html` (`<qm-home>` = `~/.questmaster`; qm session state stays separately at `~/.questmaster-state`). Never written into a repo, never committed. Go through qm to write the store; do not scribble the dotfile from agent code.
6. **The agent never sets quest status.** Status (wip/active/done) is human-only. A quest is born wip; the human approves it to active; the human marks it done.
7. **Only active quests are attachable.**
8. **Mine qm and scry for conventions.** Match existing keymaps, TUI patterns, and prompt-inject style. If a convention already exists, follow it. On real ambiguity, stop and leave a note rather than inventing.
9. **Stay in stage.** Gate execution and the iterate-to-green loop are Stage 2. Do not build them. Gates are authored and displayed only.

## Where to stop and surface

Two acceptance points are human judgment, not automatable. Build up to them, then surface a working build for review rather than self-certifying:
- The quests app (the log in the shell pane): does check / edit / toggle / approve feel right (Task 7)?
- The tracker: does it give the quest-to-session picture (Task 8)?

## Branch & review

Do the implementation on a dedicated **feature branch off `main`** (e.g. `quests-in-qm`). Commit per task and push the branch so the diffs are reviewable; do **not** merge to `main` until reviewed. `main` already carries these plan docs.

## Pushing

This folder belongs in the qm repo (`docs/quests/`) and is already on `main`. Commit and push your work to the feature branch, so a remote or cloud session sees everything on clone. A local-only commit is not visible to a fresh clone.
