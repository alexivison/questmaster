#!/usr/bin/env bash
#
# Sandbox harness for testing the Quests feature WITHOUT touching your running
# questmaster. It builds qm into a scratch dir and points QUESTMASTER_HOME and
# QUESTMASTER_STATE_ROOT at the sandbox, so your real ~/.questmaster and
# ~/.questmaster-state are never read or written. Quests are never committed.
#
# Usage:
#   scripts/quests-sandbox.sh setup     # build + seed sample quests (default)
#   scripts/quests-sandbox.sh board     # launch the interactive quest board (TUI)
#   scripts/quests-sandbox.sh tracker   # preview the tracker quest line (TUI)
#   scripts/quests-sandbox.sh cli       # print a guided CLI walkthrough
#   scripts/quests-sandbox.sh run ARGS  # run the sandboxed qm with any args
#   scripts/quests-sandbox.sh gates     # go build ./... && go test ./... && go vet ./...
#   scripts/quests-sandbox.sh where     # print the sandbox paths + env
#   scripts/quests-sandbox.sh clean     # delete the sandbox
#
# The sandbox lives at $QM_SANDBOX (default: $TMPDIR/qm-quests-sandbox) and
# persists across invocations so `setup` then `board` shows the seeded quests.
#
# NOTE: `qm session new/attach` spawn real tmux panes + agent CLIs, so this
# harness never runs them. The `tracker` command instead seeds fake sandboxed
# sessions and launches the tracker with a STUB tmux on PATH, so it shows the
# quest line without touching your real tmux server or running questmaster
# (it is read-only: press q to quit).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SANDBOX="${QM_SANDBOX:-${TMPDIR:-/tmp}/qm-quests-sandbox}"
BIN="$SANDBOX/bin/qm"

export QUESTMASTER_HOME="$SANDBOX/home"
export QUESTMASTER_STATE_ROOT="$SANDBOX/state"

c_dim=$'\033[2m'; c_cyan=$'\033[36m'; c_amber=$'\033[33m'; c_off=$'\033[0m'

note() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off"; }
step() { printf '\n%s$ %s%s\n' "$c_cyan" "$*" "$c_off"; }

build() {
  mkdir -p "$SANDBOX/bin"
  note "building qm → $BIN"
  ( cd "$REPO_ROOT" && go build -o "$BIN" . )
}

ensure_bin() { [ -x "$BIN" ] || build; }

# _qm runs the sandboxed binary with the sandbox env.
_qm() { ensure_bin; "$BIN" "$@"; }

# seed_quest <id> <wip|active|done> <json-file>
# Scaffolds a quest, replaces its JSON with the prepared body via a non-
# interactive $EDITOR (cp src over the edit buffer), then moves it to the
# requested status through the real approve/done transitions.
seed_quest() {
  local id="$1" status="$2" json="$3"
  _qm quest new "$id" >/dev/null
  EDITOR="cp $json" _qm quest edit "$id" >/dev/null
  case "$status" in
    active) _qm quest approve "$id" >/dev/null ;;
    done)   _qm quest approve "$id" >/dev/null; _qm quest done "$id" >/dev/null ;;
    wip)    ;;
    *) echo "seed_quest: unknown status $status" >&2; return 1 ;;
  esac
  note "seeded $id ($status)"
}

# fake_attach <quest-id> <session-id>... — writes sandboxed session-state files
# so the board's derived "on it" indicator and the tracker quest line have data
# to show, without spawning tmux.
fake_attach() {
  local quest="$1"; shift
  for sid in "$@"; do
    mkdir -p "$QUESTMASTER_STATE_ROOT/$sid"
    cat > "$QUESTMASTER_STATE_ROOT/$sid/state.json" <<EOF
{"session_id":"$sid","version":1,"quest_id":"$quest","panes":{},"seen_at":"2026-06-02T00:00:00Z"}
EOF
  done
  note "fake-attached $quest → $*"
}

seed() {
  ensure_bin
  rm -rf "$QUESTMASTER_HOME" "$QUESTMASTER_STATE_ROOT"
  local tmp="$SANDBOX/seed"; mkdir -p "$tmp"

  cat > "$tmp/DEMO-1.json" <<'JSON'
{
  "id": "DEMO-1",
  "title": "Widget shell refactor",
  "status": "wip",
  "summary": "Bring the shared layout to the web app, retiring the legacy shell across every route it still owns.",
  "date": "2026-05-28",
  "agent": "codex",
  "project": "example-app",
  "related": [
    { "type": "linear", "title": "TASK-1", "url": "https://linear.app/acme/issue/TASK-1" },
    { "type": "linear", "title": "TASK-2", "url": "https://linear.app/acme/issue/TASK-2" },
    { "type": "github", "title": "PR-1",   "url": "https://github.com/acme/web/pull/1" }
  ],
  "gates": [
    { "name": "tests",  "type": "auto",   "check": "cmd:make test" },
    { "name": "ci",     "type": "auto",   "check": "github:checks" },
    { "name": "review", "type": "toggle", "before": "pr" },
    { "name": "ui-ok",  "type": "toggle" }
  ],
  "body": [
    { "type": "heading", "level": 2, "text": "Context" },
    { "type": "text", "text": "The legacy shell is duplicated per route and drifts. Phase 3 replaces it with the shared layout and one navigation source." },
    { "type": "heading", "level": 2, "text": "Approach" },
    { "type": "list", "ordered": true, "items": [
      "Land the layout behind the existing flag",
      "Migrate routes in batches",
      "Keep visual parity until cutover"
    ] },
    { "type": "rich", "format": "mermaid", "fallback": "diagram: route migration order", "content": "graph LR; legacy --> shared --> cutover" },
    { "type": "code", "lang": "ts", "text": "flag.enable('example-flag')" }
  ]
}
JSON

  cat > "$tmp/DEMO-2.json" <<'JSON'
{
  "id": "DEMO-2", "title": "Settings catalog", "status": "wip",
  "summary": "Ship the Settings catalog review-setup catalog.",
  "project": "example-app", "date": "2026-05-26", "agent": "claude",
  "gates": [
    { "name": "tests", "type": "auto", "check": "cmd:make test" },
    { "name": "review", "type": "toggle", "before": "pr" }
  ],
  "body": [ { "type": "text", "text": "Catalog the basic review-setup cases and wire them to the shared layout." } ]
}
JSON

  cat > "$tmp/DEMO-3.json" <<'JSON'
{
  "id": "DEMO-3", "title": "Settings migration", "status": "wip",
  "summary": "Migrate the settings surface onto the Widget layout.",
  "project": "example-app",
  "gates": [ { "name": "tests", "type": "auto", "check": "cmd:make test" } ],
  "body": [ { "type": "text", "text": "Follows DEMO-1; do not start until the layout has landed." } ]
}
JSON

  cat > "$tmp/DEMO-4.json" <<'JSON'
{
  "id": "DEMO-4", "title": "Settings phase 3 draft", "status": "wip",
  "summary": "Draft of the Phase 3 scope — not yet approved.",
  "body": [ { "type": "text", "text": "Rough notes; gates still being defined." } ]
}
JSON

  cat > "$tmp/DEMO-5.json" <<'JSON'
{
  "id": "DEMO-5", "title": "Inline preview", "status": "wip",
  "summary": "Inline preview for direct-edit mode.",
  "gates": [ { "name": "tests", "type": "auto", "check": "cmd:make test" } ],
  "body": [ { "type": "text", "text": "Shipped: preview renders inline on edit." } ]
}
JSON

  seed_quest DEMO-1 active "$tmp/DEMO-1.json"
  seed_quest DEMO-2  active "$tmp/DEMO-2.json"
  seed_quest DEMO-3 active "$tmp/DEMO-3.json"
  seed_quest DEMO-4  wip    "$tmp/DEMO-4.json"
  seed_quest DEMO-5 done   "$tmp/DEMO-5.json"

  # Two sessions on DEMO-1, one on DEMO-2; DEMO-3 stays unattached ("wait").
  fake_attach DEMO-1 qm-1780292528 qm-1780295973
  fake_attach DEMO-2  qm-1780273049
}

cmd_setup() {
  build
  seed
  printf '\n%sSandbox ready.%s Try:\n' "$c_amber" "$c_off"
  echo "  scripts/quests-sandbox.sh board      # the TUI (human gate 1)"
  echo "  scripts/quests-sandbox.sh cli        # CLI walkthrough"
  echo "  scripts/quests-sandbox.sh run quest view DEMO-1"
}

cmd_board() { _qm quest board; }

# stub_tmux writes a no-op tmux into the sandbox so the tracker preview never
# reaches the real tmux server: list/has-session report "no sessions", every
# other call is a successful no-op (so a stray keypress can't spawn anything).
stub_tmux() {
  mkdir -p "$SANDBOX/stub"
  cat > "$SANDBOX/stub/tmux" <<'EOF'
#!/bin/sh
case "$1" in
  has-session|list-sessions) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$SANDBOX/stub/tmux"
}

# seed_tracker writes fake manifests + one session-state with a quest_id so the
# tracker has a master (on DEMO-1) + worker + free standalone to render.
seed_tracker() {
  mkdir -p "$QUESTMASTER_STATE_ROOT/qm-master"
  local cwd="$HOME/Code/example-app"
  cat > "$QUESTMASTER_STATE_ROOT/qm-master.json" <<EOF
{"session_id":"qm-master","session_type":"master","title":"Widget shell refactor","cwd":"$cwd","workers":["qm-worker"],"agents":[{"name":"claude","role":"primary","cli":"claude","window":0}]}
EOF
  cat > "$QUESTMASTER_STATE_ROOT/qm-worker.json" <<EOF
{"session_id":"qm-worker","title":"Shared layout","cwd":"$cwd","parent_session":"qm-master","agents":[{"name":"claude","role":"primary","cli":"claude","window":0}]}
EOF
  cat > "$QUESTMASTER_STATE_ROOT/qm-free.json" <<EOF
{"session_id":"qm-free","title":"fix flaky auth test","cwd":"$cwd","agents":[{"name":"claude","role":"primary","cli":"claude","window":0}]}
EOF
  cat > "$QUESTMASTER_STATE_ROOT/qm-master/state.json" <<EOF
{"session_id":"qm-master","version":1,"quest_id":"DEMO-1","panes":{"primary":{"role":"primary","agent":"claude","state":"idle"}},"seen_at":"2026-06-02T00:00:00Z"}
EOF
}

cmd_tracker() {
  ensure_bin
  # Need the DEMO-1 quest in the store so the line resolves its goal.
  [ -f "$QUESTMASTER_HOME/quests/DEMO-1.html" ] || seed
  stub_tmux
  seed_tracker
  note "read-only preview · tmux is stubbed · press q to quit"
  PATH="$SANDBOX/stub:$PATH" TMUX="" QUESTMASTER_SESSION="qm-master" "$BIN"
}

cmd_cli() {
  ensure_bin
  step "qm quest ls"; _qm quest ls
  step "qm quest view DEMO-1"; _qm quest view DEMO-1
  step "qm quest validate DEMO-1"; _qm quest validate DEMO-1
  printf '\n'
  note "approve/done are human-only; try: scripts/quests-sandbox.sh run quest done DEMO-2"
  note "open in a browser:               scripts/quests-sandbox.sh run quest open DEMO-1"
}

cmd_run() { _qm "$@"; }

cmd_gates() {
  ( cd "$REPO_ROOT" && set -x && go build ./... && go test ./... && go vet ./... )
}

cmd_where() {
  echo "sandbox:               $SANDBOX"
  echo "QUESTMASTER_HOME:      $QUESTMASTER_HOME"
  echo "QUESTMASTER_STATE_ROOT:$QUESTMASTER_STATE_ROOT"
  echo "qm binary:             $BIN"
  echo
  echo "quest files:"
  ls -1 "$QUESTMASTER_HOME/quests" 2>/dev/null | sed 's/^/  /' || echo "  (none — run setup)"
}

cmd_clean() { rm -rf "$SANDBOX"; note "removed $SANDBOX"; }

main() {
  local cmd="${1:-setup}"; shift || true
  case "$cmd" in
    setup) cmd_setup ;;
    seed)  build; seed ;;
    board) cmd_board ;;
    tracker) cmd_tracker ;;
    cli)   cmd_cli ;;
    run)   cmd_run "$@" ;;
    gates) cmd_gates ;;
    where) cmd_where ;;
    clean) cmd_clean ;;
    help|-h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "${BASH_SOURCE[0]}" ;;
    *) echo "unknown command: $cmd (try: help)" >&2; exit 2 ;;
  esac
}

main "$@"
