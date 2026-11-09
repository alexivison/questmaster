#!/usr/bin/env bash
# Git status widget for tmux status bar (GitHub Dark Dimmed palette)
cd "$1" 2>/dev/null || exit 0

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || exit 0

[[ ${#BRANCH} -gt 25 ]] && BRANCH="${BRANCH:0:25}…"

ICON_BRANCH=$(printf '\xf3\xb0\x98\xac')
ICON_PLUS=$(printf '')
ICON_MINUS=$(printf '')
ICON_QUESTION=$(printf '')

CHANGED="" INSERTIONS="" DELETIONS="" UNTRACKED=""

STATUS=$(git status --porcelain 2>/dev/null | grep -cE "^(M| M)")
if [[ $STATUS -ne 0 ]]; then
  read -r C I D <<< "$(git diff --numstat 2>/dev/null | awk 'NF==3 {c+=1; i+=$1; d+=$2} END {printf("%d %d %d", c, i, d)}')"
  [[ $C -gt 0 ]] && CHANGED="#[fg=#d0a647,bold] ${C} "
  [[ $I -gt 0 ]] && INSERTIONS="#[fg=#5aa75f,bold] ${ICON_PLUS} ${I} "
  [[ $D -gt 0 ]] && DELETIONS="#[fg=#e7716b,bold] ${ICON_MINUS} ${D} "
fi

U=$(git ls-files --other --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
[[ $U -gt 0 ]] && UNTRACKED="#[fg=#64707d,bold] ${ICON_QUESTION} ${U} "

echo "#[fg=#768390] ${ICON_BRANCH} $BRANCH ${CHANGED}${INSERTIONS}${DELETIONS}${UNTRACKED}#[default]"
