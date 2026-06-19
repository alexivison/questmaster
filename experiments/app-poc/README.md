# Questmaster App POC

Throwaway macOS-first app experiment for pairing a real terminal workspace with local Questmaster HTML.

## Run

```sh
cd experiments/app-poc
swift run QuestmasterAppPoc
```

Useful flags:

```sh
swift run QuestmasterAppPoc --session qm-1781764872
swift run QuestmasterAppPoc --no-tmux
swift run QuestmasterAppPoc --quest /Users/aleksi.tuominen/.questmaster/quests/quest-1781670566.html
```

By default the app loads `/Users/aleksi.tuominen/.questmaster/quests/quest-1781670566.html`.
The terminal attaches to `$QUESTMASTER_SESSION` when set, otherwise the newest `qm-*` tmux session, otherwise a login shell.

## Stack

- Swift Package Manager executable.
- AppKit `NSWindow` + `NSSplitView`.
- SwiftTerm `LocalProcessTerminalView` for a PTY-backed terminal.
- WebKit `WKWebView` for Questmaster HTML.

## GhosttyKit check

The installed Ghostty cask only exposes `Ghostty.app` and does not include a local `GhosttyKit`, `libghostty`, or Swift module. A SwiftPM `GhosttyKit` wrapper exists, but it is a separate binary XCFramework package and its public examples are centered on host-managed/mock I/O. For this POC, SwiftTerm is the fastest credible fallback to test UX with real terminal programs.

## Scope

No Questmaster production code is imported or modified. The app owns no Questmaster state. Closing or crashing the app only tears down the app's PTY client process; existing tmux sessions should remain alive.
