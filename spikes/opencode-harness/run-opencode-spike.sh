#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="real"
out_dir=""
timeout="${OPENCODE_SPIKE_TIMEOUT_SECONDS:-120}"
qm_session="${QUESTMASTER_SESSION:-qm-opencode-spike}"

usage() {
  cat <<'EOF'
Usage:
  spikes/opencode-harness/run-opencode-spike.sh [--real|--simulate] [--out DIR]

Modes:
  --real       Run a real OpenCode TUI in tmux, capture plugin events, test resume,
               and relay a prompt with tmux send-keys. Requires opencode auth.
  --simulate   Feed representative OpenCode events through the spike plugin with Bun.

Environment:
  OPENCODE_SPIKE_MODEL             Optional provider/model override for real runs.
                                  Defaults to opencode/big-pickle for the spike.
  OPENCODE_SPIKE_TIMEOUT_SECONDS   Per-step timeout, default 120.
  QUESTMASTER_SESSION              Questmaster session id exposed to the plugin.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --real)
      mode="real"
      shift
      ;;
    --simulate)
      mode="simulate"
      shift
      ;;
    --out)
      out_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$out_dir" ]]; then
  out_dir="$(mktemp -d "${TMPDIR:-/tmp}/questmaster-opencode-spike.XXXXXX")"
else
  mkdir -p "$out_dir"
fi
out_dir="$(cd "$out_dir" && pwd)"

require_bin() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 127
  fi
}

if [[ "$mode" == "simulate" ]]; then
  require_bin bun
  bun "$script_dir/simulate-plugin-events.mjs" "$out_dir"
  exit 0
fi

require_bin opencode
require_bin tmux

project_dir="$out_dir/project"
mkdir -p "$project_dir/.opencode/plugins" "$project_dir/.opencode/agents"
cp "$script_dir/questmaster-spike-plugin.js" "$project_dir/.opencode/plugins/questmaster-spike.js"
cp "$script_dir/questmaster-spike-agent.md" "$project_dir/.opencode/agents/questmaster-spike.md"

initial_events="$out_dir/real-initial-events.ndjson"
initial_state="$out_dir/real-initial-state.json"
initial_pane="$out_dir/real-initial-pane.txt"
resume_events="$out_dir/real-resume-events.ndjson"
resume_state="$out_dir/real-resume-state.json"
resume_pane="$out_dir/real-resume-pane.txt"
summary="$out_dir/summary.txt"

initial_tmux="qm-oc-spike-initial-$$"
resume_tmux="qm-oc-spike-resume-$$"

cleanup() {
  tmux kill-session -t "$initial_tmux" >/dev/null 2>&1 || true
  tmux kill-session -t "$resume_tmux" >/dev/null 2>&1 || true
}
trap cleanup EXIT

model="${OPENCODE_SPIKE_MODEL:-opencode/big-pickle}"
model_args=(--model "$model")

capture_pane() {
  local session="$1"
  local pane="$2"
  tmux capture-pane -p -t "$session:0.0" >"$pane" 2>/dev/null || true
}

wait_for() {
  local description="$1"
  local check="$2"
  local error_file="${3:-}"
  local i
  for ((i = 0; i < timeout; i++)); do
    if eval "$check"; then
      return 0
    fi
    if [[ -n "$error_file" ]] && grep -q '"type":"session.error"' "$error_file" 2>/dev/null; then
      echo "OpenCode emitted session.error while waiting for $description" >&2
      echo "see $error_file" >&2
      return 1
    fi
    sleep 1
  done
  echo "timeout waiting for $description" >&2
  return 1
}

extract_session_id() {
  sed -n 's/.*"opencode_session_id":"\([^"]*\)".*/\1/p' "$1" | head -n 1
}

initial_prompt="Remember token QM_SPIKE_OK. Reply exactly QM_SPIKE_OK and do not use tools."
resume_prompt="What exact token did you output in the first assistant message of this session? Reply only that token."

echo "run dir: $out_dir"
echo "OpenCode: $(opencode --version)"
echo "model: $model"

tmux new-session -d -s "$initial_tmux" -c "$project_dir" \
  "env QUESTMASTER_SESSION='$qm_session' QUESTMASTER_OPENCODE_SPIKE_EVENTS='$initial_events' QUESTMASTER_OPENCODE_SPIKE_STATE='$initial_state' opencode --mini --agent questmaster-spike --prompt '$initial_prompt' ${model_args[*]} --print-logs --log-level INFO"

wait_for "initial prompt completion" \
  "capture_pane '$initial_tmux' '$initial_pane'; grep -q '\"type\":\"session.idle\"' '$initial_events' 2>/dev/null && { grep -q 'QM_SPIKE_OK' '$initial_events' 2>/dev/null || grep -q 'QM_SPIKE_OK' '$initial_pane' 2>/dev/null; }" \
  "$initial_events"

capture_pane "$initial_tmux" "$initial_pane"
tmux kill-session -t "$initial_tmux" >/dev/null 2>&1 || true

session_id="$(extract_session_id "$initial_events")"
if [[ -z "$session_id" ]]; then
  echo "failed to extract OpenCode session id from $initial_events" >&2
  exit 1
fi
echo "captured OpenCode session id: $session_id"

tmux new-session -d -s "$resume_tmux" -c "$project_dir" \
  "env QUESTMASTER_SESSION='$qm_session' QUESTMASTER_OPENCODE_SPIKE_EVENTS='$resume_events' QUESTMASTER_OPENCODE_SPIKE_STATE='$resume_state' opencode --mini --session '$session_id' --agent questmaster-spike ${model_args[*]} --print-logs --log-level INFO"

sleep 6
tmux send-keys -t "$resume_tmux:0.0" -l "$resume_prompt"
tmux send-keys -t "$resume_tmux:0.0" Enter

wait_for "resume relay completion" \
  "capture_pane '$resume_tmux' '$resume_pane'; grep -q '\"type\":\"session.idle\"' '$resume_events' 2>/dev/null && { grep -q 'QM_SPIKE_OK' '$resume_events' 2>/dev/null || grep -q 'QM_SPIKE_OK' '$resume_pane' 2>/dev/null; }" \
  "$resume_events"

capture_pane "$resume_tmux" "$resume_pane"
tmux kill-session -t "$resume_tmux" >/dev/null 2>&1 || true

cat >"$summary" <<EOF
OpenCode version: $(opencode --version)
Model: $model
Questmaster session env: $qm_session
Project dir: $project_dir
Captured OpenCode session id: $session_id
Initial events: $initial_events
Initial state: $initial_state
Resume events: $resume_events
Resume state: $resume_state
Relay prompt: $resume_prompt
Expected relay/resume answer: QM_SPIKE_OK

Result:
- local plugin loaded from project .opencode/plugins without --pure
- plugin saw QUESTMASTER_SESSION
- session.created exposed properties.sessionID early enough to persist
- opencode --session resumed the captured session id
- tmux send-keys delivered a prompt to an idle resumed TUI
EOF

cat "$summary"
