# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.10] - 2026-05-26

### Fixed

- Tracker working-duration suffixes now appear for legacy or preserved `working` panes that lack `working_since`, falling back to `last_event`. Claude, Codex, and Pi hooks now persist a stable `WorkingSince` while working and clear stale values when panes leave the `working` state. (#21)

## [0.2.9] - 2026-05-25

### Changed

- Master prompt gains a HARD RULE (6): operate in a dedicated git worktree before spawning workers. Workers inherit the master's worktree by design. Standalone prompt gets an appended hint pointing at the same pattern, since standalone sessions can be promoted via `questmaster promote`. The worktree gate keeps two master sessions from colliding on the same tree; workers inside a single master continue to share the tree on purpose. (#20)

## [0.2.8] - 2026-05-25

### Added

- Tracker rows now display how long a session has been in the `working` state — e.g. `working 12s`, `working 2m14s`, `working 1h3m`. Sub-second precision is dropped; seconds are omitted past an hour. The duration is preserved across PreToolUse/PostToolUse cycles within the same turn (continuously counts up) and cleared when the session leaves the working state. (#19)
- New `PaneState.WorkingSince` field on the hook schema. Additive — SchemaVersion stays at 1.

## [0.2.7] - 2026-05-25

### Fixed

- Tracker no longer downgrades a `working` session to `unknown` after 60 seconds of hook-event silence. Long Claude thinking phases (no hook fires during pure reasoning) were false-positiving as `unknown`; now the last-known state is preserved until a new hook event arrives. (#18)

### Removed

- `sessionactivity.Evaluate`'s unused `now time.Time` parameter and the `Result.Stale` field that nothing consumed.

## [0.2.6] - 2026-05-25

### Changed

- Tracker pane title now uses a dedicated `trackerTitleStyle` (renders in the terminal's default text color, bold) so it can evolve independently of the manifest and error pane title styles. (#16)
- Pruned 13 unused style vars from `internal/tui/style.go` (`inactiveBorderStyle`, `activeBorderStyle`, `activeTextStyle`, `warnTextStyle`, `noteTextStyle`, `currentIndicatorStyle`, `currentSessionStyle`, `sessionBoxBorderStyle`, `selectedBoxBorderStyle`, `segmentSepStyle`, `spinnerStyle`, `snippetStyleWide`, `snippetStyleNarrow`). (#16)
- `questmaster resize` is now silent on success. Errors still flow through cobra's normal path. Makes the command well-behaved for non-interactive callers like tmux `run-shell` keybindings. (#17)

## [0.2.5] - 2026-05-25

### Changed

- `make install` now runs `go install github.com/alexivison/questmaster@latest` with the env vars needed for the private module path (`GOPRIVATE`, `GOSUMDB=off`, `GOPROXY=direct`) and `GOBIN` pointed at `$(HOME)/.local/bin`. The installed binary now reports the real tagged version (e.g. `questmaster v0.2.5`) instead of `dev`. For uncommitted-source dev iteration, use `go build` / `go run .` directly.

## [0.2.4] - 2026-05-25

### Changed

- Master / standalone / worker system prompts consolidated into a single shared set (`internal/agent/prompts.go`); each provider now returns the same canonical text instead of three near-identical per-agent copies.
- Master prompt gains an explicit anti-polling rule: worker `questmaster report` output already arrives as input, so masters should not run `sleep` / repeated `questmaster read` polling loops.
- Worker prompt rule (1) clarified — the ban applies only to nested *questmaster* worker sessions; in-agent helpers (Task tool, subagents, agent-transport companion) remain available. Fixes Codex/Pi workers over-interpreting the previous phrasing and refusing all sub-agent dispatches.
- Standalone prompt stripped of harness self-disclosure and reduced to a one-line questmaster CLI cheatsheet (no role framing).

## [0.2.3] - 2026-05-25

### Changed

- Picker worker rows now use the tracker's `┣━` / `┗━` tree connectors (dim gutter color) instead of a gold `│ `, mirroring the tracker's visual language.

### Fixed

- Selecting a worker row in the picker no longer hides its tree connector. The leading glyph survives the reverse-video selection bar so the row keeps its visual link to the master above.

## [0.2.2] - 2026-05-25

### Fixed

- Tracker is back as the leftmost pane in the workspace window instead of a separate `Tracker` tmux window. Master, standalone, and worker sessions all share the single-window `tracker | primary | shell` layout. Regression from 0.2.0 when the companion pane was removed.

### Changed

- Canonical pane widths are now 16% (tracker) / 45% (shell) — slightly narrower tracker, wider shell. `questmaster resize` and the layout helper both reflect the new widths.

## [0.2.1] - 2026-05-25

### Changed

- `questmaster workers` and `questmaster status` surface the hook-derived pane state (working/idle/blocked/done/starting) instead of only tmux liveness. Stopped sessions render the state word once in the tracker title line.
- Master and standalone prompts use neutral orchestration language; PR / file-line / evidence vocabulary is no longer baked into the binary.

### Removed

- **Breaking:** Removed `questmaster config` command and user-global `~/.config/questmaster/config.toml` support. Select the primary agent with `--primary <agent>`; override binary paths with `CLAUDE_BIN` / `CODEX_BIN` / `PI_BIN`.
- **Breaking:** Removed `questmaster agent query evidence-required` — workflow concept that belonged to external hooks, not questmaster.
- Removed legacy `party-cli` migration code, `MIGRATING.md`, and the Pi legacy marker cleanup path. Existing `party-cli` users should upgrade via `0.2.0` first if they still need the migration.

## [0.2.0] - 2026-05-23

### Added

- Hook handlers now write `claude_session_id` and `codex_thread_id` to the session manifest, enabling automatic resume across reboots for Claude and Codex (matching Pi's existing capture).
- Missing-agent-binary errors from `start` and `continue` now name the binary, the `*_BIN` override env var, and the fallback install path.

### Changed

- README prerequisites name each supported agent CLI with install links, default-primary behavior, and binary override/fallback paths.

### Removed

- **Breaking:** Removed same-session companion panes and the `--companion` flag from `spawn`, `start`, and `continue`. Standalone sessions now match the master layout (tracker + workspace). For peer-agent review, use your agent harness's sub-agents.
- Removed `questmaster prune --artifacts` so questmaster no longer reaches into `~/.claude`, `~/.codex`, or `~/.pi` directories owned by agent vendors.

### Fixed

- Hook installer idempotency: re-running `questmaster hooks install` no longer duplicates entries.
- Test state-root isolation: developers with `QUESTMASTER_STATE_ROOT` or `PARTY_STATE_ROOT` set in their shell can now run `go test ./...` without the suite contaminating their real state directory.

## [0.1.0] - 2026-05-22

### Added

- Initial standalone `questmaster` CLI and TUI release.
- `questmaster hooks install --dry-run` for previewing hook installer changes.

### Changed

- Primary binary and module path are now `github.com/alexivison/questmaster`.
- State defaults to `~/.questmaster-state`; `PARTY_STATE_ROOT` remains a compatibility alias.
