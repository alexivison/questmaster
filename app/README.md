# Questmaster App

macOS-first app shell for pairing the real Questmaster tmux workflow with native surfaces fed by `qm serve`.

## Run

```sh
swift run --package-path app Questmaster
```

Useful flags:

```sh
swift run --package-path app Questmaster --session qm-1781764872
swift run --package-path app Questmaster --no-tmux
swift run --package-path app Questmaster --quest-id DEMO-1
swift run --package-path app Questmaster --serve-socket /path/to/qm-serve.sock --quest-id quest-1781670566
swift run --package-path app Questmaster --no-serve-launch --serve-socket /path/to/qm-serve.sock
swift run --package-path app Questmaster --no-serve
swift run --package-path app Questmaster --focus-socket /path/to/app-focus.sock
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

Configure tmux edge bindings in the user's tmux config to call `qm focus` at pane boundaries.

## Stack

- Swift Package Manager executable.
- AppKit `NSWindow` + `NSSplitView`.
- GhosttyKit/libghostty terminal surface mounted through a `TerminalPaneHosting` seam.
- Native AppKit Tracker, Quest list, and Quest viewer rendered from pushed Runtime JSON.
- Unix-domain socket newline-delimited JSON serve client, with a local stub on the same envelope/data shape.
- App-managed `qm serve` lifecycle.

## GhosttyKit

GhosttyKit 0.8.0 wrapper sources are vendored in `Vendor/GhosttyKit-0.8.0` and consumed through
local SwiftPM targets in `Package.swift`; SwiftPM resolves the binary xcframework from the hosted release artifact. The embedded surface reads the user's
real Ghostty config directly through libghostty, including font, palette or
theme, padding, and cursor settings from `~/.config/ghostty/config`. Startup
logs include the resolved Ghostty config path and libghostty diagnostics.

On the GhosttyKit path, tmux is started by setting the embedded surface command
to a generated startup script that execs `tmux new-session -A`. The script syncs
the real user `HOME`, `XDG_CONFIG_HOME`, `PATH`, `SHELL`, locale, and
Questmaster focus variables into tmux before attaching, so existing tmux
sessions do not keep stale app or test environment.

After the embedded surface attaches, the app records the tmux client created for
that surface. Tracker session switches retarget that client with
`tmux switch-client -c` and resync the tmux environment, so the existing Ghostty
surface stays mounted instead of flashing a fresh local terminal while tmux
starts. If the embedded client cannot be identified, the app falls back to
creating a new surface and attaches through the same startup script.

## Scope

No Questmaster production code is imported by the Swift app. The app owns no
Questmaster state; it starts `qm serve`, renders pushed state as a client, and
stops only the serve process it launched. Closing or crashing the app does not
kill existing tmux sessions.
