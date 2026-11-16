#!/usr/bin/env bash
# Git status widget. Colours are supplied by the generated Questmaster theme.
cd "$1" 2>/dev/null || exit 0
BORDER=${2:-{{controlBorder}}} GOLD=${3:-{{gitAmber}}} GREEN=${4:-{{gitGreen}}} RED=${5:-{{gitRed}}} DIM=${6:-{{textMeta}}}

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
  [[ $C -gt 0 ]] && CHANGED="#[fg=${GOLD},bold] ${C} "
  [[ $I -gt 0 ]] && INSERTIONS="#[fg=${GREEN},bold] ${ICON_PLUS} ${I} "
  [[ $D -gt 0 ]] && DELETIONS="#[fg=${RED},bold] ${ICON_MINUS} ${D} "
fi

U=$(git ls-files --other --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
[[ $U -gt 0 ]] && UNTRACKED="#[fg=${DIM},bold] ${ICON_QUESTION} ${U} "

echo "#[fg=${BORDER}] ${ICON_BRANCH} $BRANCH ${CHANGED}${INSERTIONS}${DELETIONS}${UNTRACKED}#[default]"
