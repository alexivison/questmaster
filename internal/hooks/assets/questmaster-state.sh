#!/bin/sh
# questmaster state hook v1 — managed by `questmaster hooks install`
# Generated; do not edit. Re-install via `questmaster hooks install` to refresh.
SESSION_ID="$QUESTMASTER_SESSION"
if [ -n "$SESSION_ID" ] && command -v questmaster >/dev/null 2>&1; then
    questmaster hook --session "$SESSION_ID" __AGENT__ "$1" >/dev/null 2>&1 || true
fi
echo '{}'
