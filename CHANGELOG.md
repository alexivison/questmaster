# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
