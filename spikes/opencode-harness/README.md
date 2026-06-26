# OpenCode harness Phase 0 spike

This directory is a dev-only proof for Questmaster OpenCode harness parity. It
does not register OpenCode as a supported Questmaster harness.

## What this proves

- Launch prompt strategy: use OpenCode TUI flags `--agent <name>` and
  `--prompt <text>`. The role/system prompt belongs in project or global
  OpenCode agent config, not in an invented CLI flag.
- Plugin path: a project-local `.opencode/plugins/*.js` plugin loads without
  `--pure`, sees `QUESTMASTER_SESSION`, and receives `session.created` with
  `properties.sessionID` early enough to persist.
- State path: the plugin writes raw event NDJSON plus a compact Questmaster-style
  state JSON through queued async file writes. Hook handlers return immediately
  after scheduling writes.
- Resume path: `opencode --session <captured-id>` resumes the native OpenCode
  session. Pass `--agent questmaster-spike` on resume too; otherwise the resumed
  TUI can use the default `build` agent for the next prompt.
- Relay path: `tmux send-keys` can deliver a prompt to an idle resumed OpenCode
  TUI and get a response that depends on resumed context.

## Run it

Real OpenCode run, requiring authenticated OpenCode and tmux:

```sh
spikes/opencode-harness/run-opencode-spike.sh --real
```

The runner defaults to `opencode/big-pickle`, which is the model verified in
the committed real fixture. Optional model override:

```sh
OPENCODE_SPIKE_MODEL=opencode/gpt-5.1-codex \
  spikes/opencode-harness/run-opencode-spike.sh --real
```

Local simulation for tool, permission, idle, and error payload mapping:

```sh
spikes/opencode-harness/run-opencode-spike.sh --simulate
```

Both modes print the output directory. The real mode writes:

- `real-initial-events.ndjson`
- `real-initial-state.json`
- `real-initial-pane.txt`
- `real-resume-events.ndjson`
- `real-resume-state.json`
- `real-resume-pane.txt`
- `summary.txt`

Committed fixtures:

- `fixtures/real-opencode-1.17.11/`: representative payloads and state from a
  real OpenCode 1.17.11 TUI/plugin run.
- `fixtures/simulated/`: representative tool, permission, idle, and error
  payloads passed through the same plugin mapping.

## Version/API assumption

Verified locally with OpenCode `1.17.11`. Treat that as the minimum supported
version until an older version is explicitly tested. The spike relies on:

- local plugin autoload from `.opencode/plugins/`
- plugin `event` hook delivery
- event names including `session.created`, `session.status`, `session.idle`,
  `message.updated`, `message.part.updated`, `tool.execute.*`,
  `permission.*`, and `session.error`
- `properties.sessionID` on session/message/status events
- TUI flags `--agent`, `--prompt`, and `--session`

## Relay limitations

`tmux send-keys` is viable only when the TUI is idle and the prompt editor has
focus. It cannot safely deliver through a busy turn, permission modal, command
palette, or any future modal state without a state gate. A Phase 1/2
implementation should gate relay on plugin state (`idle` and not
`needs_input`) or revisit OpenCode server/TUI prompt APIs if they gain clearer
submit semantics.
