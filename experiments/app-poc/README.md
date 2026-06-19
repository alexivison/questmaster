# Questmaster App POC

Throwaway macOS-first app experiment for pairing a real terminal workspace with native Questmaster surfaces fed by `qm serve`.

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
```

By default the app uses a local push stub that emits the S1 serve contract shape.
Pass `--serve-socket` or set `QUESTMASTER_SERVE_SOCKET` to connect to a real `qm serve` Unix-domain socket.
The terminal attaches to `$QUESTMASTER_SESSION` when set, otherwise the newest `qm-*` tmux session, otherwise a login shell.

## Stack

- Swift Package Manager executable.
- AppKit `NSWindow` + `NSSplitView`.
- SwiftTerm `LocalProcessTerminalView` for a PTY-backed terminal, mounted through a `TerminalPaneHosting` seam.
- Native AppKit Tracker, Quest list, and Quest viewer rendered from pushed Runtime JSON.
- Unix-domain socket newline-delimited JSON serve client, with a local stub on the same envelope/data shape.

## GhosttyKit check

The installed Ghostty cask only exposes `Ghostty.app` and does not include a local `GhosttyKit`, `libghostty`, or Swift module. A SwiftPM `GhosttyKit` wrapper exists, but it is a separate binary XCFramework package and its public examples are centered on host-managed/mock I/O. For this POC, SwiftTerm is the fastest credible fallback to test UX with real terminal programs.

## Scope

No Questmaster production code is imported or modified. The app owns no Questmaster state. Closing or crashing the app only tears down the app's PTY client process; existing tmux sessions should remain alive. The local stub is only for S2 development before a real S1 server is attached.
