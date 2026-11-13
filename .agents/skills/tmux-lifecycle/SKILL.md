---
name: tmux-lifecycle
description: Rules for Questmaster's tmux routing, server inventory, manifests, runtime directories and session close/delete/prune lifecycle in the Go backend (internal/tmux, tmuxroute, session, state, daemon, and the continue, delete, prune and tmux audit commands). Read before changing how sessions are created, found, closed, deleted or audited.
---

# Questmaster tmux routing and session lifecycle

The always-needed tmux rules (name the server and the exact session on every call, `tmux.SessionTarget`, the pane by its `NewSession` ID, TMUX variables stripped, the default server has no operational route) are in the root `AGENTS.md`. This file holds the detail behind them. When it and the live code disagree, trust the code.

- **Every tmux call names its server and its session exactly.** New sessions
  use `tmux.DefaultServer()` (`-L questmaster`, or the validated development
  label); existing sessions use the `tmux_server` recorded in their manifests
  through `tmuxroute.Router`. Missing ownership and explicit `default` are
  errors for targeted actions; aggregates treat them as stopped and omit them
  from route/handle discovery. `qm tmux audit --backfill` upgrades stopped
  manifests to `questmaster`.
  Commands run without TMUX, TMUX_PANE and TMUX_TMPDIR, which describe the
  caller's own server.
  Session panes receive their recorded label as `QUESTMASTER_TMUX_SERVER`; dev
  panes also receive `QUESTMASTER_TMUX_LABEL` for new CLI creations. Session targets are
  `tmux.SessionTarget` (`=name:`),
  never a bare name, which tmux matches by prefix. A session's pane is targeted
  by the ID `NewSession` reports, never by index: nothing assumes window or pane
  index 0, since a server may set base-index or pane-base-index. The caller's
  own pane counts only when TMUX names this server (`callerSession`).
- `tmux-servers.json` under the state root records every named label used for
  creation before `new-session`. Production routers load these labels on
  construction, so a corrupt manifest cannot hide a former dev server from
  prune. `Router.CompleteInventory` refreshes the labels and rejects an
  unreadable record or an unavailable server. Status without a readable
  manifest uses this dedicated inventory. Audit adds
  the read-only default observation. Prune and manifest-less deletion use
  `AuditInventory`: prune preserves IDs live on default, and deletion refuses
  a matching default session before making any changes. Both refuse a failed
  default probe. Audit reports incomplete inventory as `gate="unknown"` with `inventory_error`; with a
  complete server view, prune can remove old corrupt manifests.
- **A session's runtime files live in its manifest's `runtime_dir`**, an
  owner-only `<state root>/runtime/<id>` (`state.NewRuntimeDir`,
  `state.EnsureRuntimeDir`, files through `state.WriteRuntimeFile`). The tmux
  session carries it as `QUESTMASTER_RUNTIME_DIR` for the Pi extension; readers
  take the path from one of the two, never from the ID. The dedicated server
  loads a global `session-closed` hook from the regenerated
  `<state root>/tmux/enforced.<label>.conf`; its Go handler holds the lifecycle lock
  and skips a recreated or moved session. That file also enforces the root
  ownership marker and server lifetime settings after the user-editable
  shared `questmaster.conf`. Each label has its own `reload.<label>.conf`, which
  sources the user and enforced files in one tmux command. Config reload and
  restart refuse running servers with a missing or foreign root marker. A manifest
  without the field predates it and keeps its old path until the session stops
  (`Manifest.RuntimeDirOrLegacy`, the one legacy branch).
- **Closing is not deleting.** `SessionClosed` preserves the manifest and the
  master's `workers` membership, so stopped workers remain in the tracker and
  Worker Log and a master Continue can resume them (including on reattach).
  Delete and prune deregister workers before removing their manifests;
  `message.Service.Workers` prunes entries with neither a manifest nor a live
  session. Cascade reads only the master's list, so workers deregistered by
  older close hooks need one manual Continue each to restore membership.
  The close handler rewrites its own manifest through `Store.Update` to signal
  the daemon's liveness watcher; runtime-directory removal alone is not watched.
- **The user's default server has no operational route.** `ProbeDefaultSessions`
  is the one remaining reader, used by audit, stopped-manifest backfill and
  cleanup guards to detect managed sessions that remain there. It runs only `list-sessions` through
  an explicit socket path computed from `TMUX_TMPDIR` (or `/tmp`) and the uid;
  default is never a router handle or part of operational lifecycle/messaging
  inventory. Cleanup only preserves or refuses its sessions; it cannot mutate them.
  A missing socket is empty; a failed probe makes the audit gate unknown.
  `qm tmux audit --backfill` alone writes: read manifests directly, never route
  missing ownership, take one complete live snapshot and abort before all
  writes if it fails,
  then hold each lifecycle lock while rechecking dedicated liveness. Rewrite
  only stopped absent/default ownership to `questmaster`, ignoring the dev
  label. Preserve resume IDs, watches, runtime paths and manifest age; report
  updated/live/already-set/failed counts,
  and keep it idempotent.
