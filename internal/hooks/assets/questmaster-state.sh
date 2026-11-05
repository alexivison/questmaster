#!/bin/sh
# questmaster state hook v2 — managed by `questmaster hooks install`
# Generated; do not edit. Re-install via `questmaster hooks install` to refresh.
# Always exits 0 and prints {}: a hook failure must never reach the agent.
# A missing binary or a failed run goes to the session's hook-errors.log;
# a run that exits 0 has logged its own errors there.
SESSION_ID="$QUESTMASTER_SESSION"
log_hook_error() {
    case "$SESSION_ID" in qm-*) ;; *) return 0 ;; esac
    case "$SESSION_ID" in *[!A-Za-z0-9_-]*) return 0 ;; esac
    (
        umask 077
        dir="${QUESTMASTER_STATE_ROOT:-$HOME/.questmaster-state}/$SESSION_ID"
        log="$dir/hook-errors.log"
        mkdir -p "$dir" || exit 0
        if [ -f "$log" ] && [ "$(($(wc -c < "$log")))" -ge 1048576 ]; then
            mv -f "$log" "$log.1"
        fi
        printf '%s __AGENT__/%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$log"
    ) 2>/dev/null
}
if [ -n "$SESSION_ID" ]; then
    QM_BIN=""
    if [ -x "$QUESTMASTER_BIN" ]; then
        QM_BIN="$QUESTMASTER_BIN"
    elif command -v questmaster >/dev/null 2>&1; then
        QM_BIN="questmaster"
    elif command -v qm >/dev/null 2>&1; then
        QM_BIN="qm"
    fi
    if [ -n "$QM_BIN" ]; then
        QM_ERR=$("$QM_BIN" hook --session "$SESSION_ID" __AGENT__ "$1" 2>&1 >/dev/null)
        QM_STATUS=$?
        if [ "$QM_STATUS" -ne 0 ]; then
            log_hook_error "$1" "questmaster-state.sh: $QM_BIN failed with exit $QM_STATUS: $(printf '%s' "$QM_ERR" | tr '\n' ' ' | cut -c1-2000)"
        fi
    else
        log_hook_error "$1" "questmaster-state.sh: binary not found (QUESTMASTER_BIN, questmaster and qm on PATH)"
    fi
fi
echo '{}'
