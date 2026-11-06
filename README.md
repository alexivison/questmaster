<p align="center">
  <img src="assets/banner.png" alt="Questmaster banner artwork for a tmux-based AI coding-agent orchestration CLI" width="100%">
</p>

# questmaster

`questmaster` is the tmux orchestration backend for Questmaster.app. The Go CLI starts managed agent sessions as masters, spawns workers, relays messages, and exposes runtime state plus mutation RPCs to clients. Plain shell sessions remain shells.

Questmaster.app is the intended human client. The CLI is an agent-first and automation-first command surface for the native app, scripts, hooks, and local backend integrations; it is not designed as a standalone human UI.

## Prerequisites

- macOS or Linux.
- A Go 1.25.x-capable toolchain. The module declares `go 1.25.7`; older Go versions may only work when toolchain auto-download is enabled.
- `tmux` on `PATH` (`brew install tmux`, `apt install tmux`, or your distro package manager).
- Install and authenticate at least one agent CLI: [`claude`](https://docs.anthropic.com/en/docs/claude-code/setup), [`codex`](https://developers.openai.com/codex/cli), [`opencode`](https://opencode.ai/) 1.17.11 or newer, or [`pi`](https://pi.dev/docs/latest/quickstart). A plain `questmaster start` uses `claude` by default, so install `claude` first or pass `--agent` when starting/spawning with another agent.
- For non-standard install paths, set `CLAUDE_BIN`, `CODEX_BIN`, `OPENCODE_BIN`, or `PI_BIN`. Otherwise questmaster checks the current `PATH` plus `QUESTMASTER_PATH_PREFIX`, `~/.local/bin`, and `/opt/homebrew/bin`, then the user's interactive login-shell `PATH`, then built-in fallback paths like `/opt/homebrew/bin/codex`.

## Install

```sh
go install github.com/alexivison/questmaster@latest
questmaster version
```

`go install` creates the `questmaster` binary only. If you want the optional short alias, create it yourself after installation:

```sh
mkdir -p ~/.local/bin
ln -sf "$(go env GOPATH)/bin/questmaster" ~/.local/bin/qm
qm version
```

On macOS with Questmaster.app installed, `./app/Scripts/build-app.sh` points
`~/.local/bin/questmaster` at `~/.questmaster-state/bin/current/qm`, the stable
link to the installed app's `qm`, so the global CLI always matches the app.
Don't run a separate `go install` into that name afterward — it overwrites the
symlink with a binary that stops tracking the app.

From a source checkout:

```sh
go build -buildvcs=false -o questmaster .
./questmaster version
```

## Backend quick start

These commands are intended for scripts, agents, and backend debugging. For normal interactive use, launch Questmaster.app.

```sh
questmaster start "fix-login-flow"
questmaster start --agent codex "release-triage"
questmaster spawn qm-master123 "smoke-worker" --prompt "Investigate the failing smoke test"
questmaster send qm-worker123 "Try a smaller test case."
questmaster send master "done: fixed parser edge case; regression test passes"
questmaster send all "Please report your current status."
```

Inspect state:

```sh
questmaster list
questmaster status qm-1234567890
questmaster workers qm-master123
questmaster chat qm-master123 --text
questmaster read qm-worker123 --lines 20
questmaster pr watch owner/repo#42 --session qm-worker123
questmaster pr ls --session qm-worker123
questmaster pr ls --all
questmaster pr unwatch owner/repo#42 --session qm-worker123
questmaster pr events owner/repo#42 --unread --session qm-worker123
questmaster pr events owner/repo#42 --full
questmaster pr refresh owner/repo#42 --session qm-worker123
```

`pr watch` accepts `owner/repo#number` or an HTTPS pull request URL on github.com or on a host `gh auth status` lists as logged in; other hosts are rejected. `pr events`, `pr refresh` and `pr unwatch` keep working on existing watches on any host. A watch belongs to a session and disappears when that session is deleted or pruned, or once the session reads the PR's merge event with `pr events`, so a merged PR needs no unwatch. A new `pr watch` checks the PR when the daemon can reach the host, and rejects a missing PR or one blocked by access or SSO; an unavailable daemon, timeout or rate limit leaves the watch in place. Repeating a watch does not check it again. PR activity is polled by the daemon and delivered to the watching session as a Questmaster message starting `[PR owner/repo#N]` when it is idle or done; stopped sessions keep their alerts until they resume. Questmaster is a one-way personal setup, so the monitor ignores comments and reviews by the authenticated `gh` login; they neither alert nor appear in `pr events`. If GitHub does not provide that login, no author is filtered. Delivery is at least once, so an alert can repeat after a daemon restart.

Use `pr ls --all` to find another session's watches. `pr events <ref>` can read any watched PR without changing a cursor, and marks every event `untrusted: true` with a `notice`, since comment text is data; by default it previews long bodies (400 bytes, or 200 for bots) and reports `body_truncated` and the original `body_bytes` when cut. `--full` returns whole bodies. `--unread` returns new activity and marks it read, so it requires a watch; use `--session <watcher-id>` for another session's cursor. `pr refresh` requests an immediate status check within GitHub rate limits and reports each host's `checked_at` when a poll ran, or `backoff_until` when it was skipped. Each PR status's `changed_at` moves only when that status changes, except that a legacy status first gets it on the next successful poll. Successful `pr` commands emit JSON; errors exit non-zero with a message.

Session roles use `agent` for the session's main agent. The CLI accepts
`--agent`; `--primary` has been removed. Existing manifests with role
`primary` and `state.json` files with a `panes.primary` entry are normalized
when read, and the next write stores `agent`. Existing live tmux panes tagged
`@party_role=primary` remain addressable by send/read. Newly created or
respawned panes are tagged `agent`. Historical `state.jsonl` entries are left
as written.

Subcommands are agent-first: most lifecycle, messaging, list, and status commands emit JSON for noninteractive success output. Utility commands such as `version`, `agent query`, `hooks`, and `artifact` use text; `questmaster read --text` prints raw pane text.

Install or inspect generated agent hooks:

```sh
questmaster hooks status
questmaster hooks install --dry-run
questmaster hooks install
```

Claude and Codex use shell-script hooks merged into their native config. Pi's
Questmaster extension handles inbound messages and activity; `questmaster hooks
install pi` writes its version marker and extension under `$PI_HOME` or `~/.pi`.

A hook never fails the agent and gives up after 800 ms, the wait for the
session's state lock and its tmux calls included. Its errors, a missing or
failing binary included, go to `<state root>/<session>/hook-errors.log`, which
rotates at 1 MiB. `hooks status` compares the installed script and entries
with the current ones; run `hooks install` after an upgrade.

`send` takes a session ID for a direct message, `master` to report to the
current worker's parent, or `all` to broadcast from the current master.
`--message-file <path>` and `--message-file -` supply file or stdin input.
Messages between a worker and its recorded parent use `[MASTER:<id>]` or
`[WORKER:<id>]`; other direct messages use `[FROM:<id>]`. External sends use
`[FROM:external]`, which carries no session identity. Prefixes describe the
routing relationship, not model receipt.

Messaging uses native delivery for live Claude and Pi sessions when available.
Codex sends through tmux. A direct or report send prints a `delivery` label:

- `"delivery": "accepted"`: a native socket took the message. Pi answers with
  `unconfirmed` and steers the current turn; Questmaster reports that as
  accepted. Questmaster reads no reply from Claude's socket, so accepted means
  the frame was written.
- `"delivery": "submitted"`: tmux `send-keys` typed the text and Enter into the
  pane.

Neither label means the agent read the message. `received` is reserved for a
future receipt from the harness; no path reports it today. `send all` prints
`registered`, `accepted` and `submitted` counts instead of one `delivery` label.

Claude can still hold an accepted frame. Questmaster checks only the project
`.claude` settings above the session's directory for `crossSessionInbound`, so
a user or managed policy that does not accept inbound messages can hold the
frame. New Questmaster Claude launches set `accept`; older or adopted sessions
may need an effective `accept` setting or a restart. OpenCode keeps its tmux
path and requires idle or done hook state. A native send that may have written
bytes is never retried through tmux. If the send process dies after the write,
it prints no result.

OpenCode support expects an authenticated OpenCode CLI version 1.17.11 or newer.
Questmaster writes its OpenCode plugin and role agents under
`<state-root>/opencode` and launches OpenCode with `OPENCODE_CONFIG_DIR` set
only for the Questmaster tmux session, so normal OpenCode sessions keep using
the user's own config. `questmaster hooks install opencode` can refresh those
files manually; Questmaster also refreshes them before launching OpenCode.
Questmaster launches OpenCode with explicit role-default models
(`openai/gpt-5.6-terra` for workers, `openai/gpt-5.6-sol` for masters); an
explicit Questmaster model override still wins.

OpenCode `--reasoning-effort` overrides require OpenCode 1.17.15 or newer. Only
those overridden launches use OpenCode's direct interactive split-footer mode
(`opencode run --interactive`) rather than the full TUI; normal OpenCode
sessions retain the 1.17.11+ full-TUI launch behavior.

The installed role agents provide the Questmaster master and worker
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
is set. The old real-run spike harness is gone; archived OpenCode 1.17.11
captures live in `cmd/testdata/opencode-1.17.11/`; the Go hook tests replay the
initial event capture.

## CLI

The CLI is the backend and contract surface behind Questmaster.app. It keeps lifecycle and mutation commands scriptable, emits JSON for the main backend workflows, and runs an on-demand daemon for the native client. It intentionally does not provide a standalone terminal UI.

```sh
questmaster            # show help
questmaster sessions   # print session summary
questmaster daemon start   # start the on-demand backend and wait until ready
questmaster daemon status  # inspect its identity, clients, jobs, and build
questmaster daemon stop    # cleanly stop it
```

Running `questmaster` with no subcommand prints help. Lifecycle operations such as `start`, `continue`, `spawn`, `attach`, and `delete` are available as backend commands for clients and automation. `qm attach <id>` attaches only to a live session; use `qm continue <id>` to restart a stopped one.

### Tmux servers

New sessions and workers start on Questmaster's dedicated `tmux -L questmaster` server. Existing live sessions stay on the server recorded in their manifests; a missing `tmux_server` field means the user's legacy default server. `qm attach <id>` follows that recorded route, including after a creation rollback. `tmux -L questmaster ls` lists the dedicated server; plain `tmux ls` lists only the user's default server. Use `qm tmux routes` or `qm tmux audit` to inspect both.

The first dedicated session creates `<state root>/tmux/questmaster.conf`, `git-status.sh`, and `enforced.conf`. Edit `questmaster.conf`; Questmaster writes it only once. It regenerates `enforced.conf` before server startup and loads it last, enforcing the root ownership marker, server lifetime settings, and the global `session-closed` cleanup hook. `qm tmux config path` prints the paths and effective label. After an edit, run `qm tmux config check`, then `qm tmux config reload` (or press prefix `R`). Reload adds settings but may leave removed bindings or pane settings in place; use `qm tmux restart` once the dedicated server has no sessions to apply those cleanly. `qm tmux config status` shows the running state.

`QUESTMASTER_TMUX_LABEL=dev_example` selects another dedicated label for a development build. Its value must be 1–32 lowercase letters, digits, underscores, or hyphens, and cannot be `default`. The daemon keeps this override in its own environment and identity. Managed dev panes also carry it so CLI worker spawns stay on the dev server. Existing session routing still uses the label recorded at creation, so changing the variable does not move them. Inspect an override with `tmux -L dev_example ls`.

For a rollback before legacy routing is removed, install the prior routing-capable bundle with `app/Scripts/install-app.sh --rollback`, or revert the creation selector and rebuild. New sessions then use the default server again; recorded named sessions remain reachable. Do not roll back to a bundle older than the two-server routing release while named sessions exist. Legacy routing can be removed only after `qm tmux audit` reports no live legacy managed sessions, orphans, or unknown ownership, stopped manifests are backfilled, and the user approves that removal.

For the first installed rollout, use two bundles: install the routing-capable bundle and verify legacy sessions still attach, then install the creation-flip bundle. The flip becomes live only after that second install. Start a session and compare `tmux -L questmaster ls` with plain `tmux ls`; spawn a worker from a legacy master, check messages both ways, and continue a stopped legacy session. If the second bundle needs rollback, return to the routing-capable one.

The daemon accepts runtime requests, mutations, and subscriptions after its ready handshake on a socket under `<state-root>/daemon/`. The app gets the socket from `daemon start`'s JSON record. The daemon captures a clean login environment and writes identity-owned `qm` and `questmaster` shims under `<state-root>/daemon/bin/<identity>/`. Quitting the app leaves it running until its idle exit. `daemon check-upgrade` is connect-only: when it verifies a replacement binary, the running daemon re-execs in place with the same PID and socket.

When starting a session, leave the title blank and questmaster derives one from the initial prompt when provided; otherwise the first agent hook fills it after the first message. An explicit title is always kept as-is. Agent pane headers show the session title, including after a rename.

## Model selection

Every harness launches on its role default model (workers on the worker tier,
masters on the master tier). New managed agent sessions start as masters.
`start --model <id>` and
`spawn --model <id>` override it, and the value is passed to the harness
verbatim — questmaster never validates a model id, so a model released today
works today.

`questmaster models <agent>` lists what an agent can be launched with:

```sh
questmaster models claude              # JSON, agent-first
questmaster models codex --role worker --text
questmaster models opencode --refresh  # refetch instead of using the cache
```

The list is resolved at runtime, so no questmaster release is needed when a
model ships. It merges, best-first:

1. **recent launches** — models this agent has already run here (recorded per
   session), which is what makes an unlisted model a one-time cost,
2. **the harness itself**, where it can enumerate its models (`opencode
   models`); that list is authoritative when available,
3. **the [models.dev](https://models.dev) catalog**, rendered into each
   harness's own vocabulary — bare ids for Claude and Codex, provider-qualified
   ids for OpenCode and Pi — plus the family aliases Claude accepts (`opus`,
   `sonnet`), which track the latest model in their family.

The catalog is fetched once a day and cached, distilled, in
`<state-root>/model-catalog.json`; a stale cache is still served when a fetch
fails. Set `QUESTMASTER_MODEL_CATALOG_URL` to point at another catalog, or to
`off` to never fetch — suggestions then come from the cache, the harness,
recent launches, and the built-in role defaults. Each harness declares its role
defaults and catalog sources in one place (`internal/agent`'s `ModelPolicy`).

The native app's new-session sheet has a Model row backed by the same data over
the daemon's `models` request; leaving it on `default` keeps the role default. It
resolves fresh on open and whenever the agent changes, always through
the cache described above; its refresh button (or `r` while the row is
focused) forces a refetch past that cache for the currently selected agent.

## Native macOS app

Questmaster.app is the native macOS human interface over the `qm` CLI and daemon, with an AppKit shell and SwiftUI content surfaces. The app starts or reattaches to its daemon, validates each socket connection's ready handshake, renders pushed runtime JSON, and sends mutations over the same socket. It embeds a GPU-backed libghostty terminal through GhosttyKit. The terminal attaches to a `qm-*` tmux session when one is selected, remembered, or discovered, otherwise it falls back to a local shell.

The app has three regions: Tracker on the left for repos, sessions, and agents; Terminal in the center for the tmux workspace; and Dock on the right for artifacts, with session/project/all scopes. Navigation is keyboard-first and vim-style at a high level, with `hjkl` movement patterns and region focus chords.

Build and install from a source checkout:

```sh
./app/Scripts/build-app.sh
```

The script builds the Swift package in release mode, assembles and ad-hoc codesigns `Questmaster.app`, builds the Go `qm` binary into the app bundle, stamps both with one `git describe` version (Info.plist's `CFBundleShortVersionString` and `qm version`), and installs to `/Applications/Questmaster.app` by default (`--install-path` or `QUESTMASTER_INSTALL_PATH` picks another). `Package.swift` declares macOS 14 and Swift tools 5.9; the build script also expects Go and the macOS command-line tools it calls (`swift`, `codesign`, and `install_name_tool`).

Installing is `app/Scripts/install-app.sh`, which the build script runs, so running sessions never lose `qm`:

- It stages the new bundle beside the installed one and verifies it: the signature, and a `qm` whose version matches Info.plist. A failure leaves the installed app untouched.
- It copies the bundle's `qm` to `<state root>/bin/versions/<version>-<hash>/qm` and points `<state root>/bin/current/qm`, the link sessions' hooks run, at it by one rename, then swaps the bundle by renames. If a step fails part way, the steps already taken are undone.
- The replaced bundle is kept as `Questmaster.app.previous`; `app/Scripts/install-app.sh --rollback` swaps it back and points the link at its `qm`. Versions other than the installed and previous ones (and one a running daemon uses) are pruned.
- Quit the app before installing; the script doesn't stop a running app. A running daemon keeps its binary until the script's `daemon check-upgrade` nudge replaces it.

`app/Scripts/test-install.sh` tests the installer against throwaway bundles. For a test install of the real bundle, give a temporary `--install-path`, `HOME` and `QUESTMASTER_STATE_ROOT` and pass `--isolated`, which skips LaunchServices and the daemon nudge; the installer refuses a mix of temporary and real paths.

To try the tmux feature branch before it reaches `main`, run `QUESTMASTER_TMUX_LABEL=dev_example swift run --package-path app Questmaster` from a `feat/tmux-server` worktree. Optionally set `QUESTMASTER_STATE_ROOT` or pass `--state-root` for isolated state. The non-bundle app uses `go run . daemon start --build-from <worktree>` before any installed `qm`/`questmaster` on `PATH`. Go builds the daemon at a stable worktree identity path, with a separate socket and shims; it does not replace the installed binary or daemon. It polls PRs only when started with `--jobs`. Sessions created on its named server are invisible to an installed build that predates routing: do not run `questmaster prune` from such a build while those sessions exist.

Packaged app launches start `<state root>/bin/current/qm`, the stable link the installer manages, and fall back to the bundled `qm` only while that link doesn't resolve yet (a state root nothing has installed into); `--qm-bin` overrides both. `--no-daemon-start` connects without starting a daemon, and `--daemon-socket` or `QUESTMASTER_DAEMON_SOCKET` selects a socket and also connects without starting. `--state-root` still overrides the state directory.

App-created shells use the daemon's identity shims on `PATH` via `QUESTMASTER_PATH_PREFIX` and set `QUESTMASTER_BIN` from the daemon record. Reattach/continue refreshes the tmux session environment after an app move or rebuild; already-running agent processes may need restart because their process environment is fixed. The first canonical `daemon start` migrates old app-written Application Support shims to the canonical binary; `prune` removes unused shim directories.

GhosttyKit wrapper sources live under `app/Vendor/GhosttyKit-0.8.0`, but the `GhosttyKit.xcframework` binary is not committed. `Package.swift` fetches it as the `CGhosttyKitBinary` binary target from the `ghosttykit-0.8.0` GitHub release and pins the checksum there.

## State

State defaults to `~/.questmaster-state`. Override it with `QUESTMASTER_STATE_ROOT`:

```sh
export QUESTMASTER_STATE_ROOT=/path/to/state
```

Sessions use `qm-*` IDs (for example `qm-1234567890`). The current session ID is read from `QUESTMASTER_SESSION`. Artifacts are indexed in `<state-root>/artifacts.json`; newly created files live in the project-organized `<state-root>/artifact-files/` library, and per-session artifact sidecars are synced for compatibility. The model catalog is cached in `<state-root>/model-catalog.json`.

Create and register an artifact in one command (standard input supplies text, or `--from` copies an existing file):

```sh
printf '# Report\n' | questmaster artifact create report.md --label Report
questmaster artifact create diagram.png --from /path/to/diagram.png
```

The command prints the artifact ID and stored path. `questmaster artifact add <artifact-id-or-path> --session qm-...` links an existing artifact to another session without moving or copying it. `questmaster artifact rm` removes a registration or session link while keeping the file. `questmaster artifact delete <artifact-id-or-path>` permanently deletes the file and every session link.

## Development

Run the standard checks:

```sh
go mod tidy
go build -buildvcs=false ./...
go test ./...
go vet ./...
```
