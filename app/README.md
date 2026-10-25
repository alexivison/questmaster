# Questmaster App

macOS-first app shell for pairing the real Questmaster tmux workflow with native surfaces fed by the Questmaster daemon.

## Run

```sh
swift run --package-path app Questmaster
```

Useful flags:

```sh
swift run --package-path app Questmaster --session qm-1781764872
swift run --package-path app Questmaster --no-tmux
swift run --package-path app Questmaster --no-daemon-start
swift run --package-path app Questmaster --daemon-socket /path/to/qm-daemon.sock
```

By default the app runs its resolved backend's `daemon start`, reads the JSON
record, and connects to the record's socket. The daemon remains alive after the
app quits. `--no-daemon-start` only connects to an existing daemon.

Pass `--daemon-socket` or set `QUESTMASTER_DAEMON_SOCKET` to choose a socket;
this also skips `daemon start`. Pass `--qm-bin` to choose the `qm` binary, and
`--state-root` to choose the state directory. Packaged app launches use the bundled `qm`.
Non-packaged `swift run` launches from a Questmaster source checkout use the
checkout backend (`go run . daemon start --build-from <worktree>`), which builds
a stable dev executable before starting it. Daemon-owned `qm` and `questmaster`
shims go first on app-created shells' `PATH` via `QUESTMASTER_PATH_PREFIX`;
reattach/continue refreshes the tmux session
environment, while already-running agent processes may need restart because
their process environment is fixed.
The terminal attaches to `--session`/`$QUESTMASTER_SESSION` when set; otherwise it reattaches the last remembered live `qm-*` session, then the newest-created `qm-*`, otherwise a login shell.

## Stack

- Swift Package Manager executable.
- AppKit `NSWindow` + custom `MainSplitView`.
- GhosttyKit/libghostty terminal surface mounted through a `TerminalPaneHosting` seam.
- Native SwiftUI Tracker and artifact dock rendered from pushed Runtime JSON.
- Unix-domain socket newline-delimited JSON runtime/mutation client.
- An on-demand daemon that outlives the app.

## GhosttyKit

GhosttyKit 0.8.0 wrapper sources are vendored in `Vendor/GhosttyKit-0.8.0` and consumed through
local SwiftPM targets in `Package.swift`; SwiftPM resolves the binary xcframework from the hosted release artifact. The embedded surface reads the user's
real Ghostty config directly through libghostty, including font, palette or
theme, padding, and cursor settings from `~/.config/ghostty/config`. Startup
logs include the resolved Ghostty config path and libghostty diagnostics.

On the GhosttyKit path, tmux is started by setting the embedded surface command
to a generated startup script. The script creates the target session if missing,
syncs the real user `HOME`, `XDG_CONFIG_HOME`, `PATH`, `SHELL`, locale, and
app-owned Questmaster variables, respawns the placeholder pane with the login
shell, then attaches with `tmux attach-session`. App-owned variables and the
prefixed `PATH` are not written to tmux's global environment.

The startup script records the PID of the tmux client created for the embedded
surface. Tracker session switches retarget that client with `tmux switch-client
-c` and resync the tmux environment, so the existing Ghostty surface stays
mounted instead of flashing a fresh local terminal while tmux starts. If the
embedded client cannot be identified, the app falls back to creating a new
surface and attaches through the same startup script.

## Scope

No Go Questmaster production code is imported by the Swift app. The app owns no
Questmaster state; it ensures the daemon, renders pushed state, and sends
mutations as a socket client. Closing or crashing the app leaves the daemon
and existing tmux sessions running.
