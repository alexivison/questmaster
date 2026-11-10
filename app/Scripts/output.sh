# shellcheck shell=bash
# Output for build-app.sh and install-app.sh, sourced by both. On a terminal, each step is one line and a
# command's own output is kept in a log that is shown only if the step fails (its warnings are always shown).
# When stdout is not a terminal (CI, a test's capture), commands stream as before and nothing is coloured.
# NO_COLOR turns the colour off; QUESTMASTER_BUILD_VERBOSE=1 streams every command.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  UI_FANCY=1
  if [ "${COLORTERM:-}" = truecolor ] || [ "${COLORTERM:-}" = 24bit ]; then
    UI_GOLD=$'\033[1;38;2;215;177;61m' # the app's accent, #D7B13D
    UI_DIM=$'\033[38;2;141;154;168m'   # textMeta, #8D9AA8
  else
    UI_GOLD=$'\033[1;33m'
    UI_DIM=$'\033[2m'
  fi
  UI_OK=$'\033[32m'
  UI_WARN=$'\033[33m'
  UI_FAIL=$'\033[1;31m'
  UI_RESET=$'\033[0m'
else
  UI_FANCY=0
  UI_GOLD="" UI_DIM="" UI_OK="" UI_WARN="" UI_FAIL="" UI_RESET=""
fi
[ "${QUESTMASTER_BUILD_VERBOSE:-0}" = 1 ] && UI_STREAM=1 || UI_STREAM=$((1 - UI_FANCY))
UI_LABEL_WIDTH=34
# The repo root, set by the script that sources this file, tells its own warnings from a dependency's.
UI_REPO_ROOT="${UI_REPO_ROOT:-}"

# ui_title TEXT: the run's heading, between two flourishes.
ui_title() {
  printf '\n%s⚔  %s%s\n%s   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~%s\n' "${UI_GOLD}" "$1" "${UI_RESET}" "${UI_DIM}" "${UI_RESET}"
}

# ui_line LABEL MARK [NOTE]: one step's line, its label padded with dots.
ui_line() {
  local dots
  dots="$(printf '%*s' $((UI_LABEL_WIDTH - ${#1})) '' | tr ' ' '.')"
  printf '  %s◆%s %s %s%s%s %s%s\n' "${UI_GOLD}" "${UI_RESET}" "$1" "${UI_DIM}" "$dots" "${UI_RESET}" "$2" "${3:+ ${UI_DIM}$3${UI_RESET}}"
}

# ui_done LABEL [NOTE]: a step the script did itself has finished.
ui_done() { ui_line "$1" "${UI_OK}✓${UI_RESET}" "${2:-}"; }

# ui_step LABEL COMMAND...: runs a command as one step. Fails the script with its log if the command fails.
ui_step() {
  local label="$1" started=$SECONDS log status=0 warnings
  shift
  if [ "${UI_STREAM}" = 1 ]; then
    "$@"
    return
  fi
  log="$(mktemp -t questmaster-build)"
  "$@" >"$log" 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    ui_line "$label" "${UI_FAIL}✗${UI_RESET}"
    printf '\n%s' "${UI_FAIL}" >&2
    printf '  %s failed (exit %s). Its output:%s\n\n' "$label" "$status" "${UI_RESET}" >&2
    cat "$log" >&2
    rm -f "$log"
    exit "$status"
  fi
  ui_done "$label" "$((SECONDS - started))s"
  # The repo's own warnings show; a dependency's (the fetched Ghostty headers) are only counted.
  warnings="$(grep -E '(^|: )warning: ' "$log" | sort -u || true)"
  own="$(printf '%s\n' "$warnings" | grep -F "${UI_REPO_ROOT:-/nonexistent}/" | grep -vF '/.build/' || true)"
  others=$(($(printf '%s' "$warnings" | grep -c . || true) - $(printf '%s' "$own" | grep -c . || true)))
  if [ -n "$own" ]; then
    printf '%s\n' "$own" | while IFS= read -r line; do printf '      %s⚠ %s%s\n' "${UI_WARN}" "${line#"$UI_REPO_ROOT/"}" "${UI_RESET}"; done
  fi
  if [ "$others" -gt 0 ]; then
    printf '      %s%s warnings from dependencies (QUESTMASTER_BUILD_VERBOSE=1 shows them)%s\n' "${UI_DIM}" "$others" "${UI_RESET}"
  fi
  rm -f "$log"
}

# ui_fact NAME VALUE: one row of the closing summary.
ui_fact() { printf '     %s%-9s%s %s\n' "${UI_DIM}" "$1" "${UI_RESET}" "$2"; }

# ui_tilde PATH: the path with $HOME written as ~, for reading only.
ui_tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

# ui_error MESSAGE: a refusal or failure, on stderr.
ui_error() { printf '%s✗ %s%s\n' "${UI_FAIL}" "$*" "${UI_RESET}" >&2; }
