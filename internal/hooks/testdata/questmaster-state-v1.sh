#!/bin/sh
# questmaster state hook v1 — managed by `questmaster hooks install`
# Generated; do not edit. Re-install via `questmaster hooks install` to refresh.
SESSION_ID="$QUESTMASTER_SESSION"
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
        "$QM_BIN" hook --session "$SESSION_ID" __AGENT__ "$1" >/dev/null 2>&1 || true
    fi
fi
echo '{}'
