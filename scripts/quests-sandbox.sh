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
#   scripts/quests-sandbox.sh check [id]# run a quest's auto gates (Stage 2) + show the overlay
#   scripts/quests-sandbox.sh loop      # deterministic fail → inject → green loop run
#   scripts/quests-sandbox.sh picker    # open the picker to try the quest-attach step (T13)
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
IDS_FILE="$SANDBOX/ids.env"

export QUESTMASTER_HOME="$SANDBOX/home"
export QUESTMASTER_STATE_ROOT="$SANDBOX/state"

c_dim=$'\033[2m'; c_cyan=$'\033[36m'; c_amber=$'\033[33m'; c_off=$'\033[0m'

note() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off"; }
step() { printf '\n%s$ %s%s\n' "$c_cyan" "$*" "$c_off"; }

build() {
  mkdir -p "$SANDBOX/bin"
  note "building qm → $BIN"
  ( cd "$REPO_ROOT" && go build -buildvcs=false -o "$BIN" . )
}

ensure_bin() { [ -x "$BIN" ] || build; }

# _qm runs the sandboxed binary with the sandbox env.
_qm() { ensure_bin; "$BIN" "$@"; }

load_ids() { [ -f "$IDS_FILE" ] && . "$IDS_FILE"; return 0; }

rewrite_quest_id() {
  local src="$1" id="$2" dst="$3"
  awk -v id="$id" '
    !done && /"id"[[:space:]]*:/ {
      sub(/"id"[[:space:]]*:[[:space:]]*"[^"]*"/, "\"id\": \"" id "\"")
      done=1
    }
    { print }
  ' "$src" > "$dst"
}

# seed_quest <label> <wip|active|done> <json-file>
# Scaffolds a quest with qm's generated id, rewrites the fixture JSON to that id
# for the non-interactive edit buffer, then moves it to the requested status
# through the real approve/done transitions.
seed_quest() {
  local label="$1" status="$2" json="$3" out id patched
  out="$(_qm quest new)"
  id="$(printf '%s\n' "$out" | sed -n 's/Created wip quest "\([^"]*\)".*/\1/p')"
  if [ -z "$id" ]; then
    echo "seed_quest: could not parse generated id from: $out" >&2
    return 1
  fi
  patched="$SANDBOX/seed/${label}.generated.json"
  rewrite_quest_id "$json" "$id" "$patched"
  EDITOR="cp $patched" _qm quest edit "$id" >/dev/null
  case "$status" in
    active) _qm quest approve "$id" >/dev/null ;;
    done)   _qm quest approve "$id" >/dev/null; _qm quest done "$id" >/dev/null ;;
    wip)    ;;
    *) echo "seed_quest: unknown status $status" >&2; return 1 ;;
  esac
  SEEDED_ID="$id"
  note "seeded $label as $id ($status)"
}

# fake_attach <quest-id> <session-id>... — writes sandboxed session-state files
# (the quest_id link) plus a manifest with a cwd pointing at the scratch
# worktree, so the board indicator, the tracker line, AND `quest check` (which
# runs the gates in the attached session's worktree) all have data — no tmux.
fake_attach() {
  local quest="$1"; shift
  for sid in "$@"; do
    mkdir -p "$QUESTMASTER_STATE_ROOT/$sid"
    cat > "$QUESTMASTER_STATE_ROOT/$sid/state.json" <<EOF
{"session_id":"$sid","version":1,"quest_id":"$quest","panes":{},"seen_at":"2026-06-02T00:00:00Z"}
EOF
    cat > "$QUESTMASTER_STATE_ROOT/$sid.json" <<EOF
{"session_id":"$sid","cwd":"$WORKTREE"}
EOF
  done
  note "fake-attached $quest → $*"
}

seed() {
  ensure_bin
  rm -rf "$QUESTMASTER_HOME" "$QUESTMASTER_STATE_ROOT"
  local tmp="$SANDBOX/seed"; mkdir -p "$tmp"

  # A disposable "worktree" for attached sessions, with a tiny Makefile so the
  # cmd:make test gate runs to a real verdict during `quest check`.
  WORKTREE="$SANDBOX/worktree"; mkdir -p "$WORKTREE"
  printf 'test:\n\t@echo "demo tests pass"\n' > "$WORKTREE/Makefile"

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

  local DEMO1_ID DEMO2_ID DEMO3_ID DEMO4_ID DEMO5_ID
  seed_quest DEMO-1 active "$tmp/DEMO-1.json"; DEMO1_ID="$SEEDED_ID"
  seed_quest DEMO-2 active "$tmp/DEMO-2.json"; DEMO2_ID="$SEEDED_ID"
  seed_quest DEMO-3 active "$tmp/DEMO-3.json"; DEMO3_ID="$SEEDED_ID"
  seed_quest DEMO-4 wip "$tmp/DEMO-4.json"; DEMO4_ID="$SEEDED_ID"
  seed_quest DEMO-5 done "$tmp/DEMO-5.json"; DEMO5_ID="$SEEDED_ID"
  cat > "$IDS_FILE" <<EOF
DEMO1_ID=$DEMO1_ID
DEMO2_ID=$DEMO2_ID
DEMO3_ID=$DEMO3_ID
DEMO4_ID=$DEMO4_ID
DEMO5_ID=$DEMO5_ID
EOF

  # Two sessions on DEMO-1, one on DEMO-2; DEMO-3 stays unattached ("wait").
  fake_attach "$DEMO1_ID" qm-1780292528 qm-1780295973
  fake_attach "$DEMO2_ID" qm-1780273049
}

cmd_setup() {
  build
  seed
  load_ids
  printf '\n%sSandbox ready.%s Try:\n' "$c_amber" "$c_off"
  echo "  scripts/quests-sandbox.sh board      # the TUI (human gate 1)"
  echo "  scripts/quests-sandbox.sh cli        # CLI walkthrough"
  echo "  scripts/quests-sandbox.sh run quest view $DEMO1_ID --text"
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
  has-session) exit 1 ;;        # no live sessions
  list-sessions) exit 0 ;;      # empty list (success), so the picker still opens
  *) exit 0 ;;                  # every other call is a no-op
esac
EOF
  chmod +x "$SANDBOX/stub/tmux"
}

stub_gh_checks() {
  mkdir -p "$SANDBOX/stub"
  cat > "$SANDBOX/stub/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "pr view")
    printf '{"number":1,"url":"https://github.com/acme/web/pull/1","state":"OPEN"}\n'
    ;;
  "pr checks")
    printf '[{"name":"sandbox-ci","workflow":"ci","bucket":"pass","state":"SUCCESS"}]\n'
    ;;
  *)
    printf 'unexpected sandbox gh invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$SANDBOX/stub/gh"
}

# seed_tracker writes fake manifests + one session-state with a quest_id so the
# tracker has a master (on DEMO-1) + worker + free standalone to render.
seed_tracker() {
  load_ids
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
{"session_id":"qm-master","version":1,"quest_id":"$DEMO1_ID","panes":{"primary":{"role":"primary","agent":"claude","state":"idle"}},"seen_at":"2026-06-02T00:00:00Z"}
EOF
}

cmd_tracker() {
  ensure_bin
  # Need the first demo quest in the store so the line resolves its goal.
  load_ids
  [ -n "${DEMO1_ID:-}" ] && [ -f "$QUESTMASTER_HOME/quests/$DEMO1_ID.html" ] || seed
  load_ids
  stub_tmux
  seed_tracker
  note "read-only preview · tmux is stubbed · press q to quit"
  PATH="$SANDBOX/stub:$PATH" TMUX="" QUESTMASTER_SESSION="qm-master" "$BIN"
}

cmd_cli() {
  ensure_bin
  load_ids
  [ -n "${DEMO1_ID:-}" ] || { seed; load_ids; }
  step "qm quest ls --text"; _qm quest ls --text
  step "qm quest view $DEMO1_ID --text"; _qm quest view "$DEMO1_ID" --text
  step "qm quest validate $DEMO1_ID"; _qm quest validate "$DEMO1_ID"
  printf '\n'
  note "approve/done are human-only; try: scripts/quests-sandbox.sh run quest done $DEMO2_ID"
  note "open in a browser:               scripts/quests-sandbox.sh run quest open $DEMO1_ID --browser"
}

# cmd_check runs a quest's auto gates (Stage 2) in the attached scratch worktree
# and shows the verdicts, then the detail render with the ✓/✗/⚠ overlay.
cmd_check() {
  ensure_bin
  load_ids
  [ -n "${DEMO1_ID:-}" ] || { seed; load_ids; }
  local id="${1:-$DEMO1_ID}"
  stub_gh_checks
  step "qm quest check $id"
  PATH="$SANDBOX/stub:$PATH" _qm quest check "$id" || true
  step "qm quest view $id --text   (auto gates now overlaid from the sidecar)"
  _qm quest view "$id" --text
  printf '\n'
  note "tests = cmd:make test → pass (the worktree has a Makefile);"
  note "ci = github:checks → pass (sandbox gh reports PR #1 checks green)."
  note "toggles stay [ ] until you check them on the board (→ then space)."
}

stub_tmux_loop() {
  mkdir -p "$SANDBOX/loop/stub"
  cat > "$SANDBOX/loop/stub/tmux" <<EOF
#!/bin/sh
LOG="$SANDBOX/loop/injected.log"
case "\$1" in
  has-session)
    [ "\${3:-}" = "qm-loop" ] && exit 0
    exit 1
    ;;
  list-panes)
    printf '0 1 primary\n'
    ;;
  display-message)
    printf '0\n'
    ;;
  send-keys)
    last=""
    for arg in "\$@"; do last="\$arg"; done
    if [ "\$last" != "Enter" ]; then
      printf '%s\n' "\$last" >> "\$LOG"
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$SANDBOX/loop/stub/tmux"
}

loop_state() {
  local state="$1" seq="$2"
  local sec
  printf -v sec '%02d' "$seq"
  mkdir -p "$QUESTMASTER_STATE_ROOT/qm-loop"
  cat > "$QUESTMASTER_STATE_ROOT/qm-loop/state.json" <<EOF
{"session_id":"qm-loop","version":1,"quest_id":"$LOOP_ID","panes":{"primary":{"role":"primary","agent":"codex","state":"$state","seq":$seq,"last_event":"2026-06-04T00:00:${sec}Z","last_kind":"sandbox"}},"seen_at":"2026-06-04T00:00:${sec}Z"}
EOF
}

wait_for_file_nonempty() {
  local path="$1" label="$2" deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -s "$path" ] && return 0
    sleep 0.05
  done
  echo "timed out waiting for $label" >&2
  return 1
}

wait_for_pid() {
  local pid="$1" label="$2" deadline=$((SECONDS + 10))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      return $?
    fi
    sleep 0.05
  done
  echo "timed out waiting for $label" >&2
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 1
}

relay_body_from_pointer() {
  local pointer="$1"
  case "$pointer" in
    "Read and follow the instructions in "*". Act on them now, then report back with results.")
      local path="${pointer#Read and follow the instructions in }"
      path="${path%. Act on them now, then report back with results.}"
      [ -f "$path" ] && cat "$path"
      ;;
    *) printf '%s\n' "$pointer" ;;
  esac
}

cmd_loop() {
  build
  local loop_root="$SANDBOX/loop"
  rm -rf "$loop_root"
  mkdir -p "$loop_root"
  export QUESTMASTER_HOME="$loop_root/home"
  export QUESTMASTER_STATE_ROOT="$loop_root/state"

  local worktree="$loop_root/worktree"
  mkdir -p "$worktree" "$loop_root/tmp" "$QUESTMASTER_STATE_ROOT"
  cat > "$loop_root/LOOP-1.json" <<'JSON'
{
  "id": "LOOP-1",
  "title": "Sandbox loop",
  "status": "wip",
  "summary": "Demonstrate the autonomous gate loop with a failing file check that turns green after one injected prompt.",
  "gates": [
    { "name": "tests", "type": "auto", "check": "cmd:test -f fixed" }
  ],
  "body": [
    { "type": "text", "text": "The fake agent creates ./fixed after qm injects the failing gate output." }
  ]
}
JSON

  local LOOP_ID
  seed_quest LOOP-1 active "$loop_root/LOOP-1.json"
  LOOP_ID="$SEEDED_ID"

  cat > "$QUESTMASTER_STATE_ROOT/qm-loop.json" <<EOF
{"session_id":"qm-loop","title":"sandbox loop","cwd":"$worktree","session_type":"standalone","agents":[{"name":"codex","role":"primary","cli":"codex","window":0}]}
EOF
  loop_state working 1
  stub_tmux_loop

  note "running deterministic loop sandbox with stub tmux"
  PATH="$loop_root/stub:$PATH" "$BIN" quest loop qm-loop --max-iters 5 --max-time 10s --stuck-after 3 > "$loop_root/loop.out" 2>&1 &
  local loop_pid=$!

  sleep 0.2
  loop_state done 2
  wait_for_file_nonempty "$loop_root/injected.log" "injected failure prompt"

  note "fake agent received injection and fixes the worktree"
  touch "$worktree/fixed"
  loop_state working 3
  loop_state done 4

  wait_for_pid "$loop_pid" "quest loop to exit green"

  step "loop output"
  cat "$loop_root/loop.out"
  step "injected prompt body"
  relay_body_from_pointer "$(head -n 1 "$loop_root/injected.log")"
  step "final sidecar"
  cat "$QUESTMASTER_HOME/runtime/$LOOP_ID.json"

  if ! grep -q "terminal: all autos green" "$loop_root/loop.out"; then
    echo "loop did not reach green" >&2
    return 1
  fi
}

# cmd_picker launches the real session picker against the sandbox so you can see
# the quest-attach step (T13): press n (new), Tab to the "Quest:" selector,
# ←/→ to pick an active quest. tmux is stubbed, so just eyeball it and press esc
# to cancel — do not submit (the sandbox has no real agent/tmux to spawn into).
cmd_picker() {
  ensure_bin
  stub_tmux
  note "press n (new) → Tab to 'Quest:' → ←/→ to pick an active quest → esc to cancel"
  note "(stubbed tmux; this is to eyeball the quest selector, not to spawn a session)"
  PATH="$SANDBOX/stub:$PATH" TMUX="" "$BIN" picker
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
    check) cmd_check "$@" ;;
    loop)  cmd_loop ;;
    picker) cmd_picker ;;
    run)   cmd_run "$@" ;;
    gates) cmd_gates ;;
    where) cmd_where ;;
    clean) cmd_clean ;;
    help|-h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,"");print;next} NR>1{exit}' "${BASH_SOURCE[0]}" ;;
    *) echo "unknown command: $cmd (try: help)" >&2; exit 2 ;;
  esac
}

main "$@"
