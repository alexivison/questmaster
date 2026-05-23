# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Removed

- Removed same-session peer panes and related role/config/flag wiring; sessions now use only primary agents, with tracker plus primary workspace windows.

## [0.1.0] - 2026-05-22

### Added

- Initial standalone `questmaster` CLI and TUI release.
- Hook installer migration from legacy `party-cli` state, config, hooks, and Pi markers.
- `questmaster hooks install --dry-run` for safe migration preview.

### Changed

- Primary binary and module path are now `github.com/alexivison/questmaster`.
- State defaults to `~/.questmaster-state`; `PARTY_STATE_ROOT` remains a compatibility alias.
