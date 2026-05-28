<p align="center">
  <img src="assets/banner.png" alt="Questmaster banner artwork for a tmux-based AI coding-agent orchestration CLI" width="100%">
</p>

# questmaster

`questmaster` is a tmux-based orchestration CLI and Bubble Tea TUI for running a small adventuring party of AI coding agents. It starts sessions, promotes a session to master, spawns workers, relays messages, and tracks agent activity from a terminal sidebar.

## Prerequisites

- macOS or Linux.
- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` on `PATH` (`brew install tmux`, `apt install tmux`, or your distro package manager).
- Install and authenticate at least one agent CLI: [`claude`](https://docs.anthropic.com/en/docs/claude-code/setup), [`codex`](https://developers.openai.com/codex/cli), or [`pi`](https://pi.dev/docs/latest/quickstart). A plain `questmaster start` uses `claude` by default, so install `claude` first or configure/start with another primary.
- For non-standard install paths, set `CLAUDE_BIN`, `CODEX_BIN`, or `PI_BIN`; otherwise questmaster checks `PATH`, then `~/.local/bin/claude`, `/opt/homebrew/bin/codex`, or `/opt/homebrew/bin/pi`.

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

Install or inspect generated agent hooks:

```sh
questmaster hooks status
questmaster hooks install --dry-run
questmaster hooks install
```

## TUI

Running `questmaster` with no subcommand launches the Bubble Tea tracker TUI. The TUI reads session manifests and hook activity from the questmaster state root, displays active/stale sessions, and provides keyboard-driven status tracking for the current tmux workspace.

Common entry points:

```sh
questmaster            # launch tracker TUI
questmaster sessions   # print session summary
questmaster picker     # open interactive session picker
```

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
