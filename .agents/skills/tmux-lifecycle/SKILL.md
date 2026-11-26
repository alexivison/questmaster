---
name: tmux-lifecycle
description: For working on the Questmaster codebase itself (not for users of the questmaster CLI). Rules for Questmaster's tmux routing, server inventory, manifests, runtime directories and session close/delete/prune lifecycle in the Go backend (internal/tmux, tmuxroute, session, state, daemon, and the continue, delete, prune and tmux audit commands). Read before changing how sessions are created, found, closed, deleted or audited.
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
- The daemon's `worker-attention` job inventories recorded servers once per pass
  and reads state only for live, registered workers with a live owning master.
  With no registered worker/master pair, it skips tmux and reports no work, so
  an unavailable tmux command cannot keep an otherwise idle daemon alive.
  Hook state holds one `blocked_since` token and `blocked_alerted` acknowledgement
  per episode, so pending alerts survive a daemon restart. Messages wait while the
  master is busy; a worker that resumes before delivery is no longer pending.
  Subagents temporarily waking a blocked parent preserve its unanswered episode.
  A pass resumes after its last visited row when its budget expires, so slow sends
  cannot indefinitely starve later masters. Delivered episodes awaiting their
  state acknowledgement are retained only for registered live workers and retry
  the acknowledgement without resending. These daemon acknowledgements poll a
  nonblocking flock; cancelled attempts retain no background lock waiters.
  Automatic alerts include the worker's recorded server and exact session target
  for manual inspection of a native dialog; they do not answer the dialog.
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

## Codex app-server ownership

Every new or continued Codex process uses native messaging through a session-owned
app-server. Existing plain TUI processes keep tmux delivery until relaunched;
live reattachment does not replace their transport.

The pane runs `qm agent codex`, supervising one session-owned app-server and its
foreground remote TUI. The server inherits that session's environment and role
configuration; it never starts the shared Codex daemon. Either process exiting,
or the launcher receiving a termination signal, stops the other process.
On resume, approval and sandbox overrides stay on the owning app-server; the
remote TUI rejects those overrides. Its model, effort and role overrides remain.
The private runtime carries `codex-native`, `cx.sock` (Codex's guarded alias to
an owner-only Unix socket), and a log capped at 1 MiB. Both the alias owner and
resolved socket's private parent/ownership are validated before connecting.
Session close/delete/prune owns runtime-directory removal.
Native sends rejoin only the recorded, already-loaded thread on that socket,
use `turn/start`, which atomically steers an active turn or starts an idle one
without a history query. Only an explicit refusal during manual compaction uses
`thread/queue/add` on that same owner; Codex consumes it after compaction. A missing
queue API is an error. They never answer server approval/input requests or cold-resume a missing
TUI. Once the marker exists, delivery errors do not fall back to tmux or retry an
uncertain RPC. The marker follows the transport on every relaunch, including a
dead-pane Continue; live reattachment preserves it. Restarting an exited Codex
agent with a legacy runtime allocates a private recorded runtime.

## Shared tmux theme

`internal/palette/palette.json` is the app/tmux colour source. Run
`go generate ./internal/palette` to emit Core's `Rendering/ThemePalette.swift`.
The generated `<state root>/tmux/theme.conf` uses `@questmaster_textBody`,
`@questmaster_line`, `@questmaster_color_blue` and the other semantic/named
colour options from the enforced file. `@questmaster_session_accent` is
session-local: `internal/sessiontheme` uses tracker colour precedence and worker
inheritance, sets it at launch, and refreshes live sessions after CLI/app
recolours and CLI/app config reloads. Writes are serialized under `theme.lock`
after metadata commits. Inventory is once per server; stopped sessions and
missing/default ownership are skipped. At Pi launch the same effective colour
is exported as `QUESTMASTER_SESSION_COLOR` (`#rrggbb`, or empty if unset). The
Questmaster Pi extension uses it for the input border; later recolours reach
Pi on the next agent launch.

Template v4 sources the theme. Existing user configs and status scripts are
never rewritten. To adopt it, add `source-file ~/.questmaster-state/tmux/theme.conf`
after the old visual settings (use the configured state root), then run
`qm tmux config reload`. Personal overrides go below that include. Prefix R
reloads the files and retains any session accent already set. CLI/app reloads
also remove the exact stock template-v3 border format copied onto older titled
panes, so those panes inherit the new theme; custom pane formats stay intact.
