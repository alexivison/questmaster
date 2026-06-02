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
#   scripts/quests-sandbox.sh cli       # print a guided CLI walkthrough
#   scripts/quests-sandbox.sh run ARGS  # run the sandboxed qm with any args
#   scripts/quests-sandbox.sh gates     # go build ./... && go test ./... && go vet ./...
#   scripts/quests-sandbox.sh where     # print the sandbox paths + env
#   scripts/quests-sandbox.sh clean     # delete the sandbox
#
# The sandbox lives at $QM_SANDBOX (default: $TMPDIR/qm-quests-sandbox) and
# persists across invocations so `setup` then `board` shows the seeded quests.
#
# NOTE: the session/tracker commands (qm session new/attach) spawn real tmux
# panes and agent CLIs, so this harness intentionally does NOT run them — it
# would touch your live tmux. To preview the tracker quest line without tmux,
# `setup` writes a fake (sandboxed) session-state file so one quest reads as
# attached on the board.

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

  cat > "$tmp/AEGIS-3.json" <<'JSON'
{
  "id": "AEGIS-3",
  "title": "Aegis Phase 3 rollout",
  "status": "wip",
  "summary": "Bring the Phase 3 Aegis layout to the web app, retiring the legacy common-page shell across every route it still owns.",
  "date": "2026-05-28",
  "agent": "codex",
  "project": "legalon-next",
  "related": ["NEXT-1417", "NEXT-1418", "PR-1693"],
  "gates": [
    { "name": "tests",  "type": "auto",   "check": "cmd:make test" },
    { "name": "ci",     "type": "auto",   "check": "github:checks" },
    { "name": "review", "type": "toggle", "before": "pr" },
    { "name": "ui-ok",  "type": "toggle" }
  ],
  "body": [
    { "type": "heading", "level": 2, "text": "Context" },
    { "type": "text", "text": "The legacy shell is duplicated per route and drifts. Phase 3 replaces it with the shared Aegis layout and one navigation source." },
    { "type": "heading", "level": 2, "text": "Approach" },
    { "type": "list", "ordered": true, "items": [
      "Land the layout behind the existing flag",
      "Migrate routes in batches",
      "Keep visual parity until cutover"
    ] },
    { "type": "rich", "format": "mermaid", "fallback": "diagram: route migration order", "content": "graph LR; legacy --> shared --> cutover" },
    { "type": "code", "lang": "ts", "text": "flag.enable('aegis-phase-3')" }
  ]
}
JSON

  cat > "$tmp/A2UI-2.json" <<'JSON'
{
  "id": "A2UI-2", "title": "A2UI Phase 2", "status": "wip",
  "summary": "Ship the A2UI Phase 2 review-setup catalog.",
  "project": "legalon-next", "date": "2026-05-26", "agent": "claude",
  "gates": [
    { "name": "tests", "type": "auto", "check": "cmd:make test" },
    { "name": "review", "type": "toggle", "before": "pr" }
  ],
  "body": [ { "type": "text", "text": "Catalog the basic review-setup cases and wire them to the shared layout." } ]
}
JSON

  cat > "$tmp/AEGIS-4.json" <<'JSON'
{
  "id": "AEGIS-4", "title": "Aegis settings migration", "status": "wip",
  "summary": "Migrate the settings surface onto the Aegis layout.",
  "project": "legalon-next",
  "gates": [ { "name": "tests", "type": "auto", "check": "cmd:make test" } ],
  "body": [ { "type": "text", "text": "Follows AEGIS-3; do not start until the layout has landed." } ]
}
JSON

  cat > "$tmp/A2UI-3.json" <<'JSON'
{
  "id": "A2UI-3", "title": "A2UI Phase 3 draft", "status": "wip",
  "summary": "Draft of the Phase 3 scope — not yet approved.",
  "body": [ { "type": "text", "text": "Rough notes; gates still being defined." } ]
}
JSON

  cat > "$tmp/ENG-128.json" <<'JSON'
{
  "id": "ENG-128", "title": "Direct edit preview", "status": "wip",
  "summary": "Inline preview for direct-edit mode.",
  "gates": [ { "name": "tests", "type": "auto", "check": "cmd:make test" } ],
  "body": [ { "type": "text", "text": "Shipped: preview renders inline on edit." } ]
}
JSON

  seed_quest AEGIS-3 active "$tmp/AEGIS-3.json"
  seed_quest A2UI-2  active "$tmp/A2UI-2.json"
  seed_quest AEGIS-4 active "$tmp/AEGIS-4.json"
  seed_quest A2UI-3  wip    "$tmp/A2UI-3.json"
  seed_quest ENG-128 done   "$tmp/ENG-128.json"

  # Two sessions on AEGIS-3, one on A2UI-2; AEGIS-4 stays unattached ("wait").
  fake_attach AEGIS-3 qm-1780292528 qm-1780295973
  fake_attach A2UI-2  qm-1780273049
}

cmd_setup() {
  build
  seed
  printf '\n%sSandbox ready.%s Try:\n' "$c_amber" "$c_off"
  echo "  scripts/quests-sandbox.sh board      # the TUI (human gate 1)"
  echo "  scripts/quests-sandbox.sh cli        # CLI walkthrough"
  echo "  scripts/quests-sandbox.sh run quest view AEGIS-3"
}

cmd_board() { _qm quest board; }

cmd_cli() {
  ensure_bin
  step "qm quest ls"; _qm quest ls
  step "qm quest view AEGIS-3"; _qm quest view AEGIS-3
  step "qm quest validate AEGIS-3"; _qm quest validate AEGIS-3
  printf '\n'
  note "approve/done are human-only; try: scripts/quests-sandbox.sh run quest done A2UI-2"
  note "open in a browser:               scripts/quests-sandbox.sh run quest open AEGIS-3"
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
    cli)   cmd_cli ;;
    run)   cmd_run "$@" ;;
    gates) cmd_gates ;;
    where) cmd_where ;;
    clean) cmd_clean ;;
    help|-h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    *) echo "unknown command: $cmd (try: help)" >&2; exit 2 ;;
  esac
}

main "$@"
