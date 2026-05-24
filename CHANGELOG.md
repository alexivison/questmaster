# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
