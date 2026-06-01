<p align="center">
  <img src="assets/banner.png" alt="Questmaster banner artwork for a tmux-based AI coding-agent orchestration CLI" width="100%">
</p>

# questmaster

`questmaster` is a tmux-based orchestration CLI and Bubble Tea TUI for running a small adventuring party of AI coding agents. It starts sessions, promotes a session to master, spawns workers, relays messages, and tracks agent activity from a terminal sidebar.

## Prerequisites

- macOS or Linux.
- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` on `PATH` (`brew install tmux`, `apt install tmux`, or your distro package manager).
- Install and authenticate at least one agent CLI: [`claude`](https://docs.anthropic.com/en/docs/claude-code/setup), [`codex`](https://developers.openai.com/codex/cli), [`pi`](https://pi.dev/docs/latest/quickstart), or [`omp`](https://github.com/can1357/oh-my-pi) (oh-my-pi). A plain `questmaster start` uses `claude` by default, so install `claude` first or configure/start with another primary.
- For non-standard install paths, set `CLAUDE_BIN`, `CODEX_BIN`, `PI_BIN`, or `OMP_BIN`; otherwise questmaster checks `PATH`, then `~/.local/bin/claude`, `/opt/homebrew/bin/codex`, `/opt/homebrew/bin/pi`, or `~/.local/bin/omp`.

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

### Creating sessions from the picker

Press `n` (or `m`/`N` for a master) in the picker to open the new-session form. Two shortcuts make this faster:

- **Recent directories** — on the `Dir` field, press `Ctrl-R` to fuzzy-filter the working directories you've already started sessions in (no scanning, no config). Type to narrow, `↑/↓` to pick, `Enter`/`Tab` to use, `Esc` to dismiss. Plain typing and `Tab` path-completion still work when the browser is closed.
- **Auto-generated titles** — leave `Title` blank and the session is named from your first message: from the initial prompt if you provide one, otherwise from the first message you send once the session is running (the tmux window is renamed to match). An explicit title is always kept as-is.

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
