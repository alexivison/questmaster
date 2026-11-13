---
name: app-bundle
description: Building, installing, rolling back or test-running Questmaster.app and its installer scripts (app/Scripts/build-app.sh, install-app.sh, test-install.sh), and running a branch build with a dev tmux label (QUESTMASTER_TMUX_LABEL, --state-root, QUESTMASTER_BIN). Read before touching app/Scripts or running a dev app.
---

# Questmaster app bundle, install and dev runs

Hard rules (also in the root `AGENTS.md`):

- Agents never run `build-app.sh` or `install-app.sh` against the real install. A test run uses a temporary `--install-path`, `HOME` and `QUESTMASTER_STATE_ROOT` with `--isolated`.
- Merging backend changes to `main` does not make them live in the app until the bundle is rebuilt.
- Commands run for or by a dev session use `$QUESTMASTER_BIN`, never the installed `questmaster`/`qm`; unset the real install's `QUESTMASTER_BIN` before running a dev `qm` by hand.

## Build and install

`build-app.sh` builds the Swift executable, fetches/embeds GhosttyKit, **builds
the Go `qm` binary into the bundle**, stamps both with one `git describe`
version, ad-hoc codesigns, and hands the bundle to `install-app.sh`. That stages
and verifies it beside the installed app, copies its `qm` to
`<state root>/bin/versions/<version>-<hash>/qm`, retargets the stable link
`<state root>/bin/current/qm` (what hooks and the installed app run) by rename,
swaps the bundle by renames and keeps the old one as `Questmaster.app.previous`
(`install-app.sh --rollback`). Because the app ships its own `qm`, **merging
backend changes to `main` does not make them live in the app until the bundle is
rebuilt.** Agents never run either script against the real install: a test run
uses a temporary `--install-path`, `HOME` and `QUESTMASTER_STATE_ROOT` with
`--isolated` (the installer refuses a mix), and `app/Scripts/test-install.sh`
covers the installer.

State lives at `~/.questmaster-state` (override with `QUESTMASTER_STATE_ROOT`).

## Running a branch build

For branch testing, run `QUESTMASTER_TMUX_LABEL=dev_example swift run --package-path app Questmaster`
from a worktree branched from `origin/main`. `--state-root` or `QUESTMASTER_STATE_ROOT`
can isolate its state. The non-bundle app starts a worktree-built daemon with its
own identity, socket and shims; it does not replace the installed build. The
label override is validated at daemon start, carried into the daemon's
environment and identity, and passed to managed dev panes so CLI spawns stay
on the same label. A build that
predates two-server routing must not run `prune` while named sessions exist.
Commands run for or by a dev session must use `$QUESTMASTER_BIN` (or the dev shim directory first on
`PATH`), never the installed `questmaster`/`qm`: an installed build that predates routing looks only on the
default server and reports a dev session's master as not running. A shell that carries the real
install's `QUESTMASTER_BIN` passes it to the panes it creates, so unset it before running a dev `qm` by hand.
