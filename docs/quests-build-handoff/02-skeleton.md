# Quests — Fixed Build Skeleton

> The structural contract the build agent must follow. Stage 1 is the build target. The full package tree is shown so later stages slot in without re-architecting; packages tagged **seam — do not build** are off-limits this stage. The agent does not re-decide any of the layout or the load-bearing types below.

---

## 1. Module & binaries

**One module, two binaries** (`github.com/alexivison/questmaster`). The new tool is a second binary in the existing repo, sharing the `internal/` spine, with runtime state fully isolated. This realizes the "separate, independently-installable binary" decision (`go install ./cmd/quests` builds only Quests) while letting it reuse questmaster's internals — which a separate module could not import. At cutover, `cmd/quests` is renamed to `cmd/questmaster` and the old binary is removed.

- `cmd/questmaster/` — **frozen.** Do not change its behavior. Its tests must stay green; that is the guardrail for spine refactors.
- `cmd/quests/` — **the build target.** `main.go` wires a cobra root whose bare command launches the cockpit.

**The one required change to questmaster:** the shared spine must be **parameterized on its namespace** rather than hardcoding questmaster's. Concretely, `state`, `tmux`, and session/branch naming take their roots/prefixes from a passed-in value (see `paths` below), so `quests` supplies `~/.quests`, tmux prefix `quests`, branch prefix `quest/`, etc. No config file — values come from defaults + env (`QUESTS_HOME`) + flags. This refactor is covered by questmaster's existing tests.

---

## 2. Package tree

```
questmaster/                         # module: github.com/alexivison/questmaster
├── cmd/
│   ├── questmaster/                 # [frozen]   existing binary — behavior unchanged
│   └── quests/                      # [Stage 1]  new binary: cobra root → cockpit
├── internal/
│   ├── agent/                       # [reuse]    registry, claude/codex/pi, prompts, roles
│   ├── tmux/                        # [reuse*]   Client — *prefix becomes injectable
│   ├── state/                       # [reuse*]   session state store — *root becomes injectable
│   ├── session/                     # [reuse+]   Service.Start/Spawn — +Mode, +QuestID
│   ├── hooks/                       # [reuse]    interactive state hooks (Stage 1 = interactive only)
│   ├── message/ picker/ palette/    # [reuse]    as needed by the cockpit
│   └── quests/                      # NEW        everything Quests-specific
│       ├── quest/                   # [Stage 1]  parse / render / validate the HTML quest file
│       ├── runtime/                 # [Stage 1]  RuntimeRecord (observed state; mostly read this stage)
│       ├── cockpit/                 # [Stage 1]  Bubble Tea TUI: roster | quests | detail
│       ├── review/                  # [Stage 1]  DiffViewer launcher (scry default, swappable)
│       ├── adapter/                 # [Stage 1]  ContextSource + StatusSource (PR/CI read)
│       ├── paths/                   # [Stage 1]  QUESTS_HOME / tmux prefix / branch namespacing
│       ├── gate/                    # [Stage 2 — seam, do not build]  gate runner
│       ├── loop/                    # [Stage 2 — seam, do not build]  loop controller + state machine
│       ├── supervisor/              # [Stage 2 — seam, do not build]  headless process owner
│       └── router/                  # [Stage 2 — seam, do not build]  comms / inbox
```

`* / +` mark the only edits to shared/existing code: inject the namespace (`*`), and add two fields to the session model (`+`). Everything else under `internal/quests/` is greenfield.

---

## 3. Load-bearing types & interfaces

These are fixed. The agent implements them; it does not redesign them. Forward-compat fields (used by later stages) are present now but may be zero/unpopulated in Stage 1.

### Quest (parsed JSON head — see build spec §4)

```go
type GateType string // "auto" | "toggle"

type Gate struct {
    Name   string
    Type   GateType
    Check  string // required iff Type == "auto"; "" for toggle
    Before string // "" => guards done; "pr" => barrier before PR creation
}

type Quest struct {
    ID         string
    Goal       string
    Gates      []Gate
    Next       []string
    Context    []string // refs: "linear:ENG-142", "slack:#auth", ...
    Worktree   string
    PrimaryRef string
    Budget     int
}
```

Stage 1 **parses, validates, and displays** gates; it does **not** execute them (no runner until Stage 2).

### Quest file store

```go
// Document is the whole file: validated head + raw HTML body. One file, two parts.
type Document struct {
    Head Quest
    Body []byte // raw HTML body, rendered as-is; never parsed into Quest
}

type Store interface {
    Load(id string) (*Document, error)
    Save(d *Document) error          // re-validates Head against the schema before writing
    List() ([]Quest, error)          // heads only
    Path(id string) string
}

func Parse(html []byte) (*Document, error)  // extracts id="quest-head" JSON + body
func Validate(q Quest) error                // schema conformance; refuse-malformed gate
```

`Save` refusing a malformed head (and feeding the error back) is a Stage 1 deliverable — the same refuse-and-re-engage shape gates use later.

### Runtime record (observed state — never in the file)

```go
type Status string // "draft" | "ready" | "in_progress" | "blocked" | "done"

type RuntimeRecord struct {
    QuestID     string
    Status      Status
    GateResults map[string]string   // gate name -> "green|pending|failed|unset"  (Stage 2 populates)
    Sessions    []SessionRef        // from the session spine
    PR          *PRStatus           // from the adapter (Stage 1 display)
    Attempts    []Attempt           // Stage 2+
    UpdatedAt   time.Time
}
```

In Stage 1 the harness writes `Status`, `Sessions`, and `PR`; `GateResults`/`Attempts` exist but stay empty until Stage 2.

### Session (reuse + two fields)

```go
type Mode string // "interactive" | "headless"   (Stage 1: always "interactive")

// added to the existing session model:
//   Mode    Mode
//   QuestID string  // "" for a free session; set when a quest hat is attached
```

Stage 1 builds only interactive sessions (free + planning). The `Mode` field exists so Stage 2's headless supervisor slots in without touching the model.

### Adapter (read-only this stage)

```go
type PRStatus struct {
    Number int
    URL    string
    CI     string // "green|pending|failed|none"
    Review string // "approved|pending|changes|none"
}

type StatusSource interface {            // GitHub via projdash's GraphQL reads
    PR(repo, branch string) (*PRStatus, error)
}

type ContextSource interface {           // Linear/Notion/Slack via existing MCP connectors
    Resolve(ref string) (text string, err error)
}
```

Write-back to `PrimaryRef` is Stage 2 — not in this interface yet.

### Review viewer (the swappable slot)

```go
type DiffViewer interface {
    Open(worktree, baseRef string) error // shells out; default scry, swappable via flag/env
}
```

`quest diff <id>` resolves the quest's worktree + base and calls `Open`. Nothing is embedded in the cockpit.

### Paths (the isolation layer — the namespace the spine is parameterized on)

```go
type Paths struct {
    Home         string // QUESTS_HOME; default ~/.quests
    TmuxPrefix   string // "quests"
    BranchPrefix string // "quest/"
}

func Resolve() Paths // defaults <- env (QUESTS_HOME) <- flags
```

`state` and `tmux` take their root/prefix from `Paths`. This is the whole mechanism behind running alongside questmaster.

**Quest files live in the dotfile store, never in the project source tree.** A quest is stored at `<Home>/quests/<id>.html` (e.g. `~/.quests/quests/ENG-142.html`), and the runtime record beside it. The *only* thing that lives in the repo is the worktree — the code the quest is about. The quest (the authored plan + JSON head) is personal, per-machine metadata *about* the work; the agent must never write quest files into the repo or commit them. This keeps the substrate/hat split physical: repo = artifact, dotfiles = quest.

---

## 4. Stage 2+ seams (do not build — just don't foreclose)

The skeleton already leaves room so these drop in without re-architecting:

- **`gate/`** consumes `[]Gate` (already parsed) and produces `GateResults` (field already on the record).
- **`loop/`** drives attempts (field already on the record) and reads/writes `Status`; PR creation becomes loop-owned for quests with a `Before:"pr"` gate.
- **`supervisor/`** creates `Mode:"headless"` sessions (field already present) and reads stream-json.
- **`router/`** delivers messages per `Mode`; the inbox is a `Paths.Home` subdir.

If a Stage 1 task seems to need one of these, that is the signal to **stop and flag**, not to build into Stage 2.

---

## 5. Conventions

- **Verifiability first:** `go build ./...`, `go test ./...`, `go vet ./...` must be green at the end of every slice. A slice that doesn't build is not done.
- **Vertical slices:** each task leaves the tree compiling and tested; no half-wired packages across a slice boundary.
- **On ambiguity:** follow an established questmaster convention if one exists; otherwise stop and leave a note in the task's record rather than guessing. Unattended ≠ free to invent.
- **Stay in stage:** if the obvious next step is a `Stage 2 — seam` package, stop. That boundary is a hard gate.
