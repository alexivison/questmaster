<p align="center">
  <img src="assets/banner.png" alt="Questmaster banner artwork for a tmux-based AI coding-agent orchestration CLI" width="100%">
</p>

# questmaster

`questmaster` is a tmux-based orchestration CLI and Bubble Tea TUI for running a small adventuring party of AI coding agents. It starts sessions, promotes a session to master, spawns workers, relays messages, and tracks agent activity from a terminal sidebar.

You can drive it from the terminal TUI or from Questmaster.app, a native macOS front-end over the same `qm` + tmux workflow.

## Prerequisites

- macOS or Linux.
- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` on `PATH` (`brew install tmux`, `apt install tmux`, or your distro package manager).
- Install and authenticate at least one agent CLI: [`claude`](https://docs.anthropic.com/en/docs/claude-code/setup), [`codex`](https://developers.openai.com/codex/cli), [`pi`](https://pi.dev/docs/latest/quickstart), or [`omp`](https://github.com/can1357/oh-my-pi) (oh-my-pi). A plain `questmaster start` uses `claude` by default, so install `claude` first or configure/start with another primary.
- For non-standard install paths, set `CLAUDE_BIN`, `CODEX_BIN`, `PI_BIN`, or `OMP_BIN`; otherwise questmaster checks `PATH`, the user's interactive login-shell `PATH`, then `~/.local/bin/claude`, `/opt/homebrew/bin/codex`, `/opt/homebrew/bin/pi`, or `~/.local/bin/omp`.

## Install

```sh
go install github.com/alexivison/questmaster@latest
questmaster version
```

`go install` creates the primary `questmaster` binary only. If you want the optional short alias, create it yourself after installation:

```sh
mkdir -p ~/.local/bin
ln -sf "$(go env GOPATH)/bin/questmaster" ~/.local/bin/qm
qm version
```

From a source checkout:

```sh
go build -buildvcs=false -o questmaster .
./questmaster version
```

## Quick start

```sh
questmaster start "fix-login-flow"
questmaster start --master --primary codex "release-triage"
questmaster spawn --prompt "Investigate the failing smoke test" "smoke-test-worker"
questmaster spawn --quest QUEST-1 --prompt "Work this quest's tests" "quest-worker"
questmaster relay qm-worker123 "Try a smaller test case."
questmaster report "done: fixed parser edge case; regression test passes"
```

Inspect state:

```sh
questmaster list
questmaster status qm-1234567890
questmaster workers qm-master123
questmaster read qm-worker123
```

Subcommands are agent-first: non-interactive success output is JSON by default. Use the TUI for human workflows; use `questmaster quest view --text`, `questmaster quest ls --text`, or `questmaster read --text` when you explicitly want terminal text, and `questmaster quest open --browser` to launch the rebuilt quest HTML.

Install or inspect generated agent hooks:

```sh
questmaster hooks status
questmaster hooks install --dry-run
questmaster hooks install
```

Claude and Codex use shell-script hooks merged into their native config; Pi and
omp use an activity-sidecar extension. For omp, `questmaster hooks install omp`
writes the sidecar to `~/.omp/agent/extensions/` (override the agent dir with
`PI_CODING_AGENT_DIR`), where omp auto-discovers it on the next launch.

## TUI

Running `questmaster` with no subcommand launches the Bubble Tea tracker TUI. The TUI reads session manifests and hook activity from the questmaster state root, displays active/stale sessions, and provides keyboard-driven status tracking for the current tmux workspace.

Common entry points:

```sh
questmaster            # launch tracker TUI
questmaster sessions   # print session summary
questmaster picker     # open interactive session picker
```

### Tracker keys

In the tracker list: `j`/`k` (or `↑`/`↓`) move the cursor, `Enter` attaches to an
active session or continues a stopped one, `r` relays a message to an active
session, `b` broadcasts to the current master's workers and `s` spawns a worker
(both available only when the current session is a master), `d` deletes, `m`
inspects the manifest, and `q` quits. Press `c` to recolor the selected session's left
gutter on the fly — `←→`/`h`/`l` cycle the palette (the first entry clears the
color back to inherit/default) with a live preview, `Enter` applies, `Esc`
cancels. Recoloring only touches that session; workers spawned earlier keep
their own color.

### Creating sessions from the picker

Press `n` (or `m`/`N` for a master) in the picker to open the new-session form. Two shortcuts make this faster:

- **Recent directories** — on the `Dir` field, press `Ctrl-R` to fuzzy-filter the working directories you've already started sessions in (no scanning, no config). Type to narrow, `↑/↓` to pick, `Enter`/`Tab` to use, `Esc` to dismiss. Plain typing and `Tab` path-completion still work when the browser is closed.
- **Auto-generated titles** — leave `Title` blank and the session is named from your first message: from the initial prompt if you provide one, otherwise from the first message you send once the session is running (the tmux window is renamed to match). An explicit title is always kept as-is.

## Native macOS app

Questmaster.app is a native Swift/AppKit GUI over the same `qm` CLI and Go `serve` backend. It launches or connects to `qm serve` on the local socket, renders pushed runtime JSON as a client, and embeds a GPU-backed libghostty terminal through GhosttyKit. The terminal attaches to a `qm-*` tmux session when one is selected or discovered, otherwise it falls back to a local shell.

The app has three regions: Tracker on the left for repos, sessions, and agents; Terminal in the center for the tmux workspace; and Dock on the right for the quest board and detail viewer. Navigation is keyboard-first and vim-style at a high level, with `hjkl` movement patterns, region focus chords, and tmux edge handoff through `qm focus`.

Build and install from a source checkout:

```sh
./app/Scripts/build-app.sh
```

The script builds the Swift package in release mode, assembles and ad-hoc codesigns `Questmaster.app`, builds the Go `qm` binary into the app bundle, and installs to `/Applications/Questmaster.app` by default. `Package.swift` declares macOS 13 and Swift tools 5.9; the build script also expects Go and the macOS command-line tools it calls (`swift`, `sips`, `iconutil`, `codesign`, and `install_name_tool`).

GhosttyKit wrapper sources live under `app/Vendor/GhosttyKit-0.8.0`, but the `GhosttyKit.xcframework` binary is not committed. `Package.swift` fetches it as the `CGhosttyKitBinary` binary target from the `ghosttykit-0.8.0` GitHub release and pins the checksum there.

## State

State defaults to `~/.questmaster-state`. Override it with `QUESTMASTER_STATE_ROOT`:

```sh
export QUESTMASTER_STATE_ROOT=/path/to/state
```

Sessions use `qm-*` IDs (for example `qm-1234567890`). The current session ID is read from `QUESTMASTER_SESSION`.

## Development

Run the standard checks:

```sh
go mod tidy
go build -buildvcs=false ./...
go test ./...
go vet ./...
```
