#!/bin/sh
# questmaster state hook v1 — managed by `questmaster hooks install`
# Generated; do not edit. Re-install via `questmaster hooks install` to refresh.
if [ -n "$PARTY_SESSION" ] && command -v questmaster >/dev/null 2>&1; then
    questmaster hook __AGENT__ "$1" >/dev/null 2>&1 || true
fi
echo '{}'
