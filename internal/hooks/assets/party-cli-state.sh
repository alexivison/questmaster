#!/bin/sh
# party-cli state hook v1 — managed by `party-cli hooks install`
# Generated; do not edit. Re-install via `party-cli hooks install` to refresh.
if [ -n "$PARTY_SESSION" ] && command -v party-cli >/dev/null 2>&1; then
    party-cli hook __AGENT__ "$1" >/dev/null 2>&1 || true
fi
echo '{}'
