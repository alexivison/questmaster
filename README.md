# party-cli

`party-cli` is a tmux-based orchestration CLI and Bubble Tea TUI for running a small "party" of AI coding agents. It can start regular sessions, promote a session to a master, spawn worker sessions, relay messages, and track agent activity from one terminal sidebar.

This directory is being prepared to become a standalone open-source Go module at `github.com/alexivison/questmaster`. During this Phase 1 cleanup the user-facing binary name is still **`party-cli`**; the future repository/binary rename will happen separately.

## Prerequisites

- A Go 1.25.x-capable toolchain. The module currently declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` available on `PATH`.
- At least one configured agent CLI, such as `claude`, `codex`, or `pi`.
- macOS or Linux. Tests and tmux integration are guarded for Darwin/Linux.

Optional companion/master workflows assume the matching agent skill directories exist in your home config, for example `~/.claude/skills/agent-transport`, `~/.codex/skills/agent-transport`, or `~/.pi/agent/skills/agent-transport`. The CLI can still start and manage sessions without those optional skills, but generated prompts that ask agents to dispatch companions or workers expect them to be installed.

## Install from this checkout

From this directory, the current Phase 1 binary is still `party-cli`:

```sh
go build -buildvcs=false -o party-cli .
./party-cli version
```

To install into `~/.local/bin` with the current binary name:

```sh
make install
party-cli version
```

## Future standalone install

After this directory is extracted to the standalone `github.com/alexivison/questmaster` repository and the binary rename lands, installation will use Go's module-aware installer:

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

Do not use those future commands as evidence that Phase 1 renamed anything in this dotfiles repo: the current working command here remains `party-cli`.

## Quick start

Start a regular party session in the current directory:

```sh
party-cli start "fix-login-flow"
```

Start a master/orchestrator session:

```sh
party-cli start --master --primary codex "release-triage"
```

Spawn a worker from inside a master tmux session:

```sh
party-cli spawn --prompt "Investigate the failing smoke test" "smoke-test-worker"
```

Or specify the master explicitly:

```sh
party-cli spawn party-1234567890 "docs-worker"
```

Communicate with sessions:

```sh
party-cli relay party-worker123 "Please include file:line evidence."
party-cli broadcast party-master123 "Pause before pushing; review is starting."
party-cli report "done: fixed parser edge case | PR: https://github.com/example/repo/pull/1"
```

Inspect state:

```sh
party-cli list
party-cli status party-1234567890
party-cli workers party-master123
party-cli read party-worker123
```

Install or inspect generated agent hooks:

```sh
party-cli hooks status
party-cli hooks install
```

## TUI

Running `party-cli` with no subcommand launches the Bubble Tea tracker TUI. The TUI reads session manifests and hook activity from the party state root, displays active/stale sessions, and provides keyboard-driven status tracking for the current tmux workspace.

Common entry points:

```sh
party-cli            # launch tracker TUI
party-cli sessions   # print session summary
party-cli picker     # open interactive session picker
```

The tracker is designed to run in a tmux sidebar next to agent panes. It does not require the parent dotfiles repository at runtime once the binary, config, and optional skills are installed.

No screenshot or asciinema is included in this Phase 1 dotfiles cleanup because the files under `tools/party-cli/` are still inert subdirectory content without a standalone release asset location. Add a real screenshot, GIF, or asciinema link during the Phase 2 standalone repository polish before tagging the first public release.

## Configuration

Configuration is read from XDG config under `party-cli/config.toml`:

- `$XDG_CONFIG_HOME/party-cli/config.toml`, or
- `~/.config/party-cli/config.toml` when `XDG_CONFIG_HOME` is unset.

Minimal example:

```toml
[agents.claude]
cli = "claude"

[agents.codex]
cli = "codex"

[agents.pi]
cli = "pi"

[roles.primary]
agent = "claude"

[roles.companion]
agent = "codex"
```

State defaults to `~/.party-state`. Override it with:

```sh
export PARTY_STATE_ROOT=/path/to/state
```

When launching sessions from another wrapper, set `PARTY_REPO_ROOT` if the `go run` development fallback needs to find this checkout. A normal installed `party-cli` on `PATH` does not need that fallback.

## Development

Run the standard checks from this directory:

```sh
go mod tidy
go build -buildvcs=false ./...
go test ./...
go vet ./...
```

The `.github/`, issue templates, and community files in this directory are inert while `party-cli` lives under a subdirectory of the dotfiles repository. They are intended to become active when this directory is lifted to the standalone repository root.
