<p align="center">
  <img src="assets/banner.png" alt="Questmaster banner artwork for a tmux-based AI coding-agent orchestration CLI" width="100%">
</p>

# questmaster

`questmaster` is the tmux orchestration backend for Questmaster.app. The Go CLI starts sessions, promotes a session to master, spawns workers, relays messages, and exposes runtime state to clients.

Questmaster.app is the intended human client. The CLI is an agent-first and automation-first command surface for the native app, scripts, hooks, and local backend integrations; it is not designed as a standalone human UI.

## Prerequisites

- macOS or Linux.
- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` on `PATH` (`brew install tmux`, `apt install tmux`, or your distro package manager).
- Install and authenticate at least one agent CLI: [`claude`](https://docs.anthropic.com/en/docs/claude-code/setup), [`codex`](https://developers.openai.com/codex/cli), [`opencode`](https://opencode.ai/) 1.17.11 or newer, [`pi`](https://pi.dev/docs/latest/quickstart), or [`omp`](https://github.com/can1357/oh-my-pi) (oh-my-pi). A plain `questmaster start` uses `claude` by default, so install `claude` first or configure/start with another primary.
- For non-standard install paths, set `CLAUDE_BIN`, `CODEX_BIN`, `OPENCODE_BIN`, `PI_BIN`, or `OMP_BIN`; otherwise questmaster checks `PATH`, the user's interactive login-shell `PATH`, then `~/.local/bin/claude`, `/opt/homebrew/bin/codex`, `/opt/homebrew/bin/opencode`, `/opt/homebrew/bin/pi`, or `~/.local/bin/omp`.

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

## Backend quick start

These commands are intended for scripts, agents, and backend debugging. For normal interactive use, launch Questmaster.app.

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
questmaster read qm-worker123 --lines 20
```

Subcommands are agent-first: non-interactive success output is JSON by default. Use Questmaster.app for human workflows; use `questmaster quest view --text`, `questmaster quest ls --text`, or `questmaster read --text` only when you explicitly want terminal text, and `questmaster quest open --browser` to launch the rebuilt quest HTML.

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

OpenCode support expects an authenticated OpenCode CLI version 1.17.11 or newer.
Run `questmaster hooks install opencode` to write Questmaster's OpenCode plugin
and role agents under the OpenCode config dir (`$OPENCODE_CONFIG_DIR`,
`$XDG_CONFIG_HOME/opencode`, or `~/.config/opencode`). Questmaster launches
OpenCode with an explicit `--model opencode/big-pickle`. User-facing model
override documentation is intentionally deferred until Questmaster has a
supported config surface for it.

The installed role agents provide the Questmaster master, standalone, and worker
prompts plus an OpenCode `permission` block that keeps those Questmaster agents
in allow mode as an agent-policy fallback, including OpenCode's
external-directory and doom-loop safety guards. Questmaster passes the role
agents with OpenCode's `--agent` flag rather than using an unsupported
system-prompt flag; the `opencode run --dangerously-skip-permissions` flag is
not used for the TUI harness. Relay to OpenCode sessions is gated to idle or
fresh done hook state because tmux input is unsafe while OpenCode is working or
showing a permission/modal prompt.

When testing OpenCode hooks from a source checkout, either put the checkout-built
`questmaster` first on `PATH` or set `QUESTMASTER_BIN=/path/to/questmaster`; the
installed OpenCode plugin invokes `questmaster` from `PATH` unless that variable
is set. The dev-only Phase 0 validator remains available at:

```sh
spikes/opencode-harness/run-opencode-spike.sh --real
```

## CLI

The CLI is the backend and contract surface behind Questmaster.app. It keeps lifecycle and mutation commands scriptable, emits JSON for noninteractive callers, and runs `questmaster serve` for the native client. It intentionally does not provide a standalone terminal UI.

```sh
questmaster            # show help
questmaster sessions   # print session summary
questmaster serve      # run the local JSON socket backend
```

Running `questmaster` with no subcommand prints help. Lifecycle operations such as `start`, `continue`, `spawn`, `delete`, and quest mutations are available as backend commands for clients and automation.

When starting a session, leave the title blank and questmaster derives one from the initial prompt when provided; otherwise the first agent hook can rename the tmux window after the first message. An explicit title is always kept as-is.

## Native macOS app

Questmaster.app is the native SwiftUI human interface over the `qm` CLI and Go `serve` backend. It launches or connects to `qm serve` on the local socket, renders pushed runtime JSON as a client, and embeds a GPU-backed libghostty terminal through GhosttyKit. The terminal attaches to a `qm-*` tmux session when one is selected or discovered, otherwise it falls back to a local shell.

The app has three regions: Tracker on the left for repos, sessions, and agents; Terminal in the center for the tmux workspace; and Dock on the right for the quest board and detail viewer. Navigation is keyboard-first and vim-style at a high level, with `hjkl` movement patterns, region focus chords, and tmux edge handoff through `qm focus`.

Build and install from a source checkout:

```sh
./app/Scripts/build-app.sh
```

The script builds the Swift package in release mode, assembles and ad-hoc codesigns `Questmaster.app`, builds the Go `qm` binary into the app bundle, and installs to `/Applications/Questmaster.app` by default. `Package.swift` declares macOS 14 and Swift tools 5.9; the build script also expects Go and the macOS command-line tools it calls (`swift`, `codesign`, and `install_name_tool`).

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
