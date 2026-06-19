# Questmaster App POC

macOS-first app shell for pairing the real Questmaster tmux workflow with native surfaces fed by `qm serve`.

## Run

```sh
cd experiments/app-poc
swift run QuestmasterAppPoc
```

Useful flags:

```sh
swift run QuestmasterAppPoc --session qm-1781764872
swift run QuestmasterAppPoc --no-tmux
swift run QuestmasterAppPoc --quest-id DEMO-1
swift run QuestmasterAppPoc --serve-socket /path/to/qm-serve.sock --quest-id quest-1781670566
swift run QuestmasterAppPoc --terminal-engine swiftterm
swift run QuestmasterAppPoc --no-serve-launch --serve-socket /path/to/qm-serve.sock
swift run QuestmasterAppPoc --no-serve
swift run QuestmasterAppPoc --focus-socket /path/to/app-focus.sock
```

By default the app launches `qm serve` on `<state-root>/serve.sock`, connects to
that Unix-domain socket, and stops the serve process it launched on quit. If the
socket is already active, the app treats it as externally managed and only
connects as a client. Use `--no-serve-launch` or `--external-serve` to require an
external server, and `--no-serve` to use the local push stub.

Pass `--serve-socket` or set `QUESTMASTER_SERVE_SOCKET` to choose the socket.
Pass `--serve-executable`, `--qm-bin`, or `QUESTMASTER_QM` to choose the `qm`
binary. Without an explicit binary the app resolves `qm`, `questmaster`,
`/tmp/qm`, then falls back to `go run . serve` from the repo root when available.
The terminal attaches to `$QUESTMASTER_SESSION` when set, otherwise the newest `qm-*` tmux session, otherwise a login shell.
The focus handoff socket defaults to `$QUESTMASTER_FOCUS_SOCKET`, then `<state-root>/app-focus.sock`.

## Focus handoff

`qm focus <left|down|up|right>` sends an acknowledged focus request to the running app over the focus socket. The current three-region shell maps terminal left-edge handoff to Tracker and right-edge handoff to Dock; native `ctrl+l` from Tracker and `ctrl+h` from Dock returns focus to the terminal without intercepting terminal keystrokes.

Source `qm-focus.tmux.conf` after `vim-tmux-navigator` to call `qm focus` at tmux pane edges:

```tmux
source-file /path/to/questmaster/experiments/app-poc/qm-focus.tmux.conf
```

The snippet keeps Vim panes transparent by sending `ctrl+hjkl` to Vim when Vim owns the pane, matching `vim-tmux-navigator` behavior. Plain tmux panes and copy-mode use tmux edge detection and call `qm focus` at the boundary.

## Stack

- Swift Package Manager executable.
- AppKit `NSWindow` + `NSSplitView`.
- GhosttyKit/libghostty terminal surface mounted through a `TerminalPaneHosting` seam.
- SwiftTerm `LocalProcessTerminalView` remains selectable with `--terminal-engine swiftterm`.
- Native AppKit Tracker, Quest list, and Quest viewer rendered from pushed Runtime JSON.
- Unix-domain socket newline-delimited JSON serve client, with a local stub on the same envelope/data shape.
- App-managed `qm serve` lifecycle.

## GhosttyKit

GhosttyKit 0.8.0 is vendored in `Vendor/GhosttyKit-0.8.0` and consumed through
local SwiftPM targets in `Package.swift`. The embedded surface reads the user's
real Ghostty config directly through libghostty, including font, palette or
theme, padding, and cursor settings from `~/.config/ghostty/config`. Startup
logs include the resolved Ghostty config path and libghostty diagnostics.

On the GhosttyKit path, tmux is started through shell startup using a temporary
`ZDOTDIR`, then the generated startup script execs `tmux new-session -A`. The
script syncs the real user `HOME`, `XDG_CONFIG_HOME`, `PATH`, `SHELL`, locale,
and Questmaster focus variables into tmux before attaching, so existing tmux
sessions do not keep stale app or test environment.

Provenance, rebuild steps, the path for an official libghostty swap, and the
SwiftTerm IME retirement gate live in `Docs/terminal-production.md`.

## Scope

No Questmaster production code is imported by the Swift app. The app owns no
Questmaster state; it starts `qm serve`, renders pushed state as a client, and
stops only the serve process it launched. Closing or crashing the app does not
kill existing tmux sessions.
