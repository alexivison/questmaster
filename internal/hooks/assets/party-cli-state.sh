#!/bin/sh
# party-cli state hook v1 — managed by `party-cli hooks install`
# Generated; do not edit. Re-install via `party-cli hooks install` to refresh.
[ -n "$PARTY_SESSION" ] || exit 0
command -v party-cli >/dev/null 2>&1 || exit 0
exec party-cli hook __AGENT__ "$1"
