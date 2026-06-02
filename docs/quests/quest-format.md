# Quest Format and Renderers

A quest is **JSON**, the single source of truth. The terminal reads it and renders the detail pane. A build step turns the same JSON into the browser HTML. Two renderers, one source, nothing hand-kept in sync. Because it is JSON, it is validated on every write.

## Storage

One file per quest in questmaster's dotfiles: `<qm-home>/quests/<id>.html`. The file is self-contained and browser-openable. It carries:

- the canonical quest JSON in a `<script type="application/json" id="quest">` block (the source of truth, machine-read by qm), and
- a generated body around it (the rendered plan, for the browser), plus a collapsible Source panel that pretty-prints the same JSON for in-browser audit.

On create or edit, qm validates the JSON and rebuilds the body from it. The terminal reads the JSON block and never parses the generated body. Editing goes through `qm quest edit`, which opens the extracted JSON in `$EDITOR` and rebuilds the file on save. Quests are never written into a repo and never committed.

## The JSON

```json
{
  "id": "AEGIS-3",
  "title": "Aegis Phase 3 rollout",
  "status": "active",
  "date": "2026-05-28",
  "agent": "codex",
  "project": "legalon-next",
  "related": ["NEXT-1417", "NEXT-1418", "PR-1693"],
  "summary": "Bring the Phase 3 Aegis layout to the web app, retiring the legacy common-page shell.",

  "gates": [
    { "name": "tests",  "type": "auto",   "check": "cmd:make test" },
    { "name": "ci",     "type": "auto",   "check": "github:checks" },
    { "name": "review", "type": "toggle", "before": "pr" },
    { "name": "ui-ok",  "type": "toggle" }
  ],

  "body": [
    { "type": "heading", "level": 2, "text": "Context" },
    { "type": "text", "text": "The legacy shell is duplicated per route and drifts. Phase 3 replaces it with the shared Aegis layout and one navigation source." },

    { "type": "heading", "level": 2, "text": "Approach" },
    { "type": "list", "ordered": true, "items": [
      "Land the layout behind the existing flag",
      "Migrate routes in batches",
      "Keep visual parity until cutover"
    ] },

    { "type": "rich", "format": "mermaid",
      "fallback": "diagram: route migration order",
      "content": "graph LR; legacy --> shared --> cutover" },

    { "type": "heading", "level": 2, "text": "Risk" },
    { "type": "rich", "format": "table",
      "fallback": "table: 5-row phase risk matrix",
      "content": "<table>...</table>" },

    { "type": "code", "lang": "ts", "text": "flag.enable('aegis-phase-3')" }
  ]
}
```

### Frontmatter fields

- `id` required. Stable handle, matches the filename, stamped on a session on attach.
- `title` required. Short name.
- `summary` required. One-line objective. Shown as the detail-pane objective and as a future index tile line.
- `status` required. One of `wip` | `active` | `done`. Human-owned.
- `date`, `agent`, `project`, `related`. The docs-style metadata, carried for parity with your plan docs and emitted as `<meta>` tags by the HTML build.

### gates

The definition of done. Each gate:

- `name` required.
- `type` `auto` or `toggle`.
- `check` required if `type` is `auto`, forbidden if `toggle`. Grammar (authored and displayed this stage, not executed): `cmd:<shell>`, `github:checks`, `github:review-approved`, `typecheck`, `lint`, `coverage:<min>`.
- `before` optional. Omitted guards done; `"pr"` is a barrier before PR creation.

### body (ordered blocks)

Array order is document order, so structure is preserved for free. Each block has a `type`:

- `heading` `{ level, text }`
- `text` `{ text }`
- `list` `{ ordered, items[] }`
- `code` `{ lang, text }`
- `rich` `{ format, fallback, content }` HTML-only. `format` is one of `html | table | mermaid | chart | image`. `fallback` is required: the short label the terminal shows in place of the un-renderable content. `content` is the payload.

Optional on any block: `id`, a stable handle for future referencing or `reconcile`. Left out unless needed.

## Validation (`qm quest validate <id>`)

It is JSON, so validate it. Refuse and report a specific, single-line error per problem so an authoring session can self-correct (the refuse-and-re-engage loop):

- missing `id`, `title`, `summary`, or `status`; `status` not in {wip, active, done}
- an `auto` gate without a `check`; a `toggle` gate carrying a `check`; `before` not in {"", "pr"}
- a `body` block whose fields do not match its `type`; a `rich` block missing `fallback` or `format`
- malformed JSON

## Renderers

A quest is data; two renderers turn it into views. Both consume the same parsed JSON and the same `body` block model, so a new block type is added once to the model and then implemented in both. A shared block interface keeps them in lockstep.

### Terminal renderer (quest JSON -> detail pane)

Pure and deterministic: given the quest, the derived runtime (sessions on it), and a width, it returns the rendered pane. No I/O, no globals, so it is golden-testable. This is the function that produces the mocked detail pane.

Three levels, shared styling:

- `RenderDetail(q, runtime, width)` the full detail pane.
- `RenderListRow(q, runtime, width)` one line for the quest-log list (id, goal, attached tag).
- `RenderTrackerLine(q, width)` the `id . goal` line for the tracker.

`RenderDetail` layout: header (id + status), title, meta line (project . date . agent . type), attached/party line (from runtime, not the JSON), objective (summary), definition of done (gates), related, then the body.

Body dispatch, one small function per type:

- `heading` blank line + bold coloured header; `level` sets weight and indent.
- `text` word-wrapped paragraph to width.
- `list` `. ` or `1. ` prefixed items, wrapped and indented; `ordered` picks the marker.
- `code` indented monospace block, dim, with the `lang` label; no highlighting in the terminal.
- `rich` a single placeholder line from `fallback`, for example `[mermaid] route migration order (o to open)`, in a distinct dim colour so it reads as "in the browser."
- unknown type render `fallback` if present, else `[unsupported block]`. Never panic. New block types degrade, they do not crash an old binary.

Cross-cutting: width-aware wrapping; the pane is a scrollable viewport since a body can exceed the height; colours come from one small theme palette so the terminal-honest constraints (limited colours, one background) hold. Party and attached data are injected at render time from the session scan, never stored on the quest.

Verifiability: because it is a pure function, each block type plus the rich fallback plus unknown-type degradation gets a golden test (fixture JSON + fixed width -> asserted output, ANSI stripped). That is the renderer's `[auto]` gate.

### HTML build renderer (quest JSON -> browser HTML)

The sibling: same block dispatch, HTML output. `heading` -> `h{level}`, `text` -> `p`, `list` -> `ul`/`ol`, `code` -> `pre` + highlight, `rich` -> inject `content` per `format` (mermaid div, table html, chart, raw). It also emits the docs-style `<meta>` frontmatter from the JSON, so a future quest index reads the built files the way `docs-index` reads your docs, and writes the canonical JSON into the `<script>` block plus the Source panel. Runs on save and on `quest open`.
