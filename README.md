# questmaster

`questmaster` is a tmux-based orchestration CLI and Bubble Tea TUI for running a small adventuring party of AI coding agents. It starts sessions, promotes a session to master, spawns workers, relays messages, and tracks agent activity from a terminal sidebar.

## Prerequisites

- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` available on `PATH`.
- At least one configured agent CLI, such as `claude`, `codex`, or `pi`.
- macOS or Linux.

Optional companion/master workflows assume matching agent skill directories exist in your home config, for example `~/.claude/skills/agent-transport`, `~/.codex/skills/agent-transport`, or `~/.pi/agent/skills/agent-transport`. The CLI can still start and manage sessions without those optional skills, but generated prompts that ask agents to dispatch companions or workers expect them to be installed.

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
questmaster relay party-worker123 "Please include file:line evidence."
questmaster report "done: fixed parser edge case | PR: https://github.com/example/repo/pull/1"
```

Inspect state:

```sh
questmaster list
questmaster status party-1234567890
questmaster workers party-master123
questmaster read party-worker123
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

## Configuration

Configuration is read from XDG config under `questmaster/config.toml`:

- `$XDG_CONFIG_HOME/questmaster/config.toml`, or
- `~/.config/questmaster/config.toml` when `XDG_CONFIG_HOME` is unset.

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

State defaults to `~/.questmaster-state`. Override it with `QUESTMASTER_STATE_ROOT`; legacy `PARTY_STATE_ROOT` is still read as a compatibility alias:

```sh
export QUESTMASTER_STATE_ROOT=/path/to/state
```

`PARTY_SESSION` and `party-*` session IDs remain part of the product vocabulary.

Legacy users upgrading from `party-cli` can follow [MIGRATING.md](MIGRATING.md).

## Development

Run the standard checks:

```sh
go mod tidy
go build -buildvcs=false ./...
go test ./...
go vet ./...
```
