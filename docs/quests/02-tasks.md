# Stage 1 - Quests in qm (task plan)

Goal: quests (frontmatter + gates + ordered body), validated from their JSON, rendered to a terminal detail pane and a browser HTML build, plus quest-aware spawn/attach and tracker integration, all built into qm. No gate execution, no loop, no headless. Each task is a vertical slice ending with `go build ./...`, `go test ./...`, `go vet ./...` green. `[auto]` is machine-checkable; `[human]` is a review gate. The format and renderer contracts live in `quest-format.md`.

## T1 - Quest format: parse + validate

**Scope.** Types for the quest JSON: frontmatter (`id, title, summary, status, date, agent, project, related`), `gates`, and `body` as an ordered `[]Block` discriminated by `type` (`heading, text, list, code, rich`). `Parse` reads the JSON from the `<script type="application/json" id="quest">` block. `Validate` enforces `quest-format.md`. `qm quest validate <id>`.
**Depends.** nothing.
**Acceptance.** `[auto]` golden parse of the worked example (frontmatter + gates + every body block type); a table of malformed inputs each rejected with a specific error (missing required field, bad status, auto gate without check, toggle with check, rich block missing fallback or format, unknown JSON); valid passes.
**Non-goals.** rendering, storage, gate execution.

## T2 - Terminal renderer

**Scope.** Pure functions, no I/O: `RenderDetail(q, runtime, width)`, `RenderListRow(q, runtime, width)`, `RenderTrackerLine(q, width)`. Per-`type` body dispatch with the rules in `quest-format.md`: heading, text (wrapped), list, code, and `rich` rendered as its `fallback` placeholder. Unknown block type degrades to its fallback or `[unsupported block]`, never panics. Party/attached data is passed in via `runtime`, not read from the JSON. One small theme palette. The layout target for the three render levels is `quest-ui-mockup.html`.
**Depends.** T1.
**Acceptance.** `[auto]` golden render tests (ANSI stripped) for each block type, the rich fallback line, unknown-type degradation, and width wrapping; `RenderTrackerLine` and `RenderListRow` match their one-line shapes. This is the renderer's verifiability gate.
**Non-goals.** the TUI app shell, scrolling chrome (the viewport is the app's concern), HTML output.

## T3 - HTML build renderer

**Scope.** `Build(q) -> html`: same block dispatch as T2, HTML output. heading to `h{level}`, text to `p`, list to `ul`/`ol`, code to `pre` + highlight, `rich` injects `content` per `format` (mermaid, table, chart, raw html, image). Emits the docs-style `<meta>` frontmatter from the JSON, writes the canonical JSON into the `<script>` block, and renders a collapsible Source panel. Produces the self-contained `<id>.html`.
**Depends.** T1.
**Acceptance.** `[auto]` build a fixture quest; assert the `<meta>` tags are emitted from the frontmatter, the `<script id="quest">` block round-trips to the source JSON, each body block produced its HTML, and each `rich` block's content is injected by format.
**Non-goals.** the docs index itself (parked), styling polish.

## T4 - Quest store (dotfiles) + CLI

**Scope.** Store rooted at `<qm-home>/quests/<id>.html` (`<qm-home>` = `~/.questmaster`), never a repo. `qm quest new <id>` scaffolds a `wip` quest. `qm quest ls` lists. `qm quest view <id>` prints the T2 detail render. `qm quest open <id>` runs T3 and opens the browser. `qm quest edit <id>` opens the extracted JSON in `$EDITOR`, then validates (T1) and rebuilds (T3) on save, refusing malformed.
**Depends.** T1, T2, T3.
**Acceptance.** `[auto]` new produces `status=wip`; edit round-trips JSON and rebuilds the body; malformed edit is refused with the validator error; `Path` is under `<qm-home>` and a test asserts it is not under a repo path; `view` output comes from T2.
**Non-goals.** status transitions, attachment.

## T5 - Status transitions (human-only)

**Scope.** `qm quest approve <id>` (wip to active), `qm quest done <id>` (active to done). Human commands only; no path lets an executing agent set status.
**Depends.** T4.
**Acceptance.** `[auto]` approve and done move and persist status; the working-inject path exposes no status-setting API.
**Non-goals.** deriving running state.

## T6 - Session link + derived running

**Scope.** Add `quest_id` to `SessionState`, stamped on any explicitly attached session including workers. Stamp on attach, clear on detach. Helpers: sessions-for-quest (scan) and is-attached(quest). This is the `runtime` the renderer consumes.
**Depends.** existing qm session state.
**Acceptance.** `[auto]` stamp and clear; the scan returns the right sessions per quest; a quest with no session reads unattached; existing session tests stay green.
**Non-goals.** spawn wiring, display.

## T7 - Quest-aware spawn + attach

**Scope.** `qm session new --quest <id>` and `qm spawn --quest <id>`: active-only (reject wip or done), stamp `quest_id`, seed the opening prompt with the parsed quest. `qm session attach <session> --quest <id>`: active-only, inject the brief, stamp. Detach clears.
**Depends.** T4, T6.
**Acceptance.** `[auto]` spawn on an active quest stamps the id and the prompt contains goal + gates; spawn or attach on wip or done is refused; detach clears.
**Non-goals.** the loop, agent self-attach.

## T8 - Prompt injects (working + authoring)

**Scope.** Extend qm's inject layer. Working clause (session has `quest_id`): the parsed goal + gates + plan, plus "work to the gates, you cannot mark done, re-read with `qm quest view <id>`". Authoring clause (master or standalone): how to create and write a conformant quest via qm, where it lives, gates must be real, run the validator, you cannot post or close.
**Depends.** T7.
**Acceptance.** `[auto]` a session spawned on a quest receives the working clause with the gates and the no-self-certify line; the authoring clause is present for master and standalone roles.
**Non-goals.** agent self-attach, agent-set status.

## T9 - Quests app (the board)

**Scope.** The standalone quests TUI, launched in a shell pane. A grouped list (on the board / drafts / turned in) rendered with `RenderListRow`, and a detail pane rendered with `RenderDetail` in a scrollable viewport. Check / edit / open / approve / done from here. WIP rows show but are excluded from any attach or spawn selection list. Reuse qm and scry TUI patterns and keymaps.
**Depends.** T2, T4, T5, T6.
**Acceptance.** `[auto]` model tests: list groups from the store, detail pane comes from T2, attached indicator from the T6 scan, WIP excluded from the selectable set, approve and done invoke T5. `[human]` check / edit / open / approve feels right in the shell pane.
**Non-goals.** embedding in a dashboard, a combined cockpit.

## T10 - Tracker integration

**Scope.** The qm tracker shows each explicitly attached session its quest via `RenderTrackerLine` (id + goal, no status). Free sessions show none.
**Depends.** T2, T6.
**Acceptance.** `[auto]` tracker rows show the line for explicitly attached masters, standalones, and workers, and nothing for free sessions. `[human]` the tracker gives the quest-to-session picture.
**Non-goals.** changing the tracker's core behavior.

## Done

All `[auto]` green across T1 through T10; the two `[human]` gates (T9, T10) reviewed and accepted. A quest can be authored as JSON (born wip), validated, rendered to the terminal pane and a browser build, approved to active, attached at spawn, surfaced in the log and tracker, and marked done by you. Stage 2 (the supervised native gate-loop) starts from here.
