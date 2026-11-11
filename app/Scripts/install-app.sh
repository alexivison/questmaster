#!/usr/bin/env bash
# Installs a built Questmaster.app so running sessions never lose qm.
#
# Sessions' hooks run <state root>/bin/current/qm, a symlink. The bundle's qm is copied to
# <state root>/bin/versions/<version>-<hash>/qm, and the link moves there by one rename before the
# bundle is swapped, so there is no moment when the link does not resolve. The new bundle is staged
# and verified beside the installed one; the swap is two renames, and the replaced bundle is kept as
# <install path>.previous for --rollback. If any step before the swap completes fails, the steps
# already taken are undone and the installed app and both links are left as they were.
set -euo pipefail
# shellcheck source-path=SCRIPTDIR source=output.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/output.sh"

usage() {
  echo "usage: $0 [--install-path PATH] [--expect-version VERSION] [--isolated] BUNDLE" >&2
  echo "       $0 --rollback [--install-path PATH] [--isolated]" >&2
  echo "--isolated skips LaunchServices and the daemon upgrade nudge; it needs a temporary" >&2
  echo "install path, HOME and QUESTMASTER_STATE_ROOT." >&2
  exit 2
}

die() {
  ui_error "install-app: $*"
  exit 1
}

ARGS=("$@")
INSTALL_PATH="${QUESTMASTER_INSTALL_PATH:-/Applications/Questmaster.app}"
EXPECT_VERSION=""
ISOLATED=0
ROLLBACK=0
BUNDLE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-path)
      INSTALL_PATH="${2:?missing value for --install-path}"
      shift 2
      ;;
    --expect-version)
      EXPECT_VERSION="${2:?missing value for --expect-version}"
      shift 2
      ;;
    --isolated)
      ISOLATED=1
      shift
      ;;
    --rollback)
      ROLLBACK=1
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$BUNDLE" ] || usage
      BUNDLE="$1"
      shift
      ;;
  esac
done
if [ "$ROLLBACK" = 1 ] && [ -n "$BUNDLE" ]; then usage; fi
if [ "$ROLLBACK" = 0 ] && [ -z "$BUNDLE" ]; then usage; fi

absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac }

INSTALL_PATH="$(absolute "${INSTALL_PATH%/}")"
STATE_ROOT="$(absolute "${QUESTMASTER_STATE_ROOT:-$HOME/.questmaster-state}")"
BIN_DIR="$STATE_ROOT/bin"
STABLE="$BIN_DIR/current/qm"
VERSIONS="$BIN_DIR/versions"
PATH_LINK="$HOME/.local/bin/questmaster"
PREVIOUS="$INSTALL_PATH.previous"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# physical PATH resolves symlinks in the longest existing prefix of PATH.
physical() {
  local path="$1" rest=""
  while [ ! -d "$path" ]; do
    rest="/$(basename "$path")$rest"
    path="$(dirname "$path")"
  done
  echo "$(cd -P "$path" && pwd)$rest"
}

is_temporary() {
  local path root
  path="$(physical "$1")"
  for root in /private/tmp /private/var/folders ${TMPDIR:+"$(physical "$TMPDIR")"} ${RUNNER_TEMP:+"$(physical "$RUNNER_TEMP")"}; do
    case "$path/" in "${root%/}/"*) return 0 ;; esac
  done
  return 1
}

# A mix of temporary and real paths is how a test run would reach live state, so the three paths
# are either all temporary (and --isolated) or none are.
temporary=0
for path in "$INSTALL_PATH" "$HOME" "$STATE_ROOT"; do
  if is_temporary "$path"; then temporary=$((temporary + 1)); fi
done
paths="install path $INSTALL_PATH, HOME $HOME, state root $STATE_ROOT"
if [ "$ISOLATED" = 1 ] && [ "$temporary" != 3 ]; then
  die "--isolated needs a temporary install path, HOME and state root; got $paths"
fi
if [ "$ISOLATED" = 0 ] && [ "$temporary" != 0 ]; then
  die "refusing a mix of temporary and real paths ($paths); use --isolated with all three temporary"
fi

# Serialise installs on one state root: a concurrent one could prune the version this one links.
(umask 077 && mkdir -p "$BIN_DIR")
LOCK="$BIN_DIR/install.lock"
if [ "${QUESTMASTER_INSTALL_LOCK:-}" != "$LOCK" ]; then
  QUESTMASTER_INSTALL_LOCK="$LOCK" exec lockf -t 0 "$LOCK" "$0" ${ARGS[@]+"${ARGS[@]}"}
fi

if [ -L "$BIN_DIR/current" ] || { [ -e "$BIN_DIR/current" ] && [ ! -d "$BIN_DIR/current" ]; }; then
  die "$BIN_DIR/current is not a directory"
fi
if [ -e "$STABLE" ] && [ ! -L "$STABLE" ]; then die "refusing to replace $STABLE: not a link"; fi
if [ -d "$PATH_LINK" ] && [ ! -L "$PATH_LINK" ]; then die "refusing to replace $PATH_LINK: a directory"; fi
[ -w "$(dirname "$INSTALL_PATH")" ] || die "cannot write to $(dirname "$INSTALL_PATH")"
if [ "$ROLLBACK" = 1 ] && [ ! -d "$PREVIOUS" ]; then die "no previous bundle at $PREVIOUS"; fi

STAGED="$INSTALL_PATH.staged.$$"
DISCARD="$PREVIOUS.discard.$$"
HOLD="$PREVIOUS"
CANDIDATE="$STAGED"
if [ "$ROLLBACK" = 1 ]; then
  HOLD="$INSTALL_PATH.rollback.$$"
  CANDIDATE="$PREVIOUS"
fi
LINK_OLD="$(readlink "$STABLE" || true)"
PATH_OLD="$(readlink "$PATH_LINK" || true)"
PATH_EXISTED=0
if [ -e "$PATH_LINK" ] || [ -L "$PATH_LINK" ]; then PATH_EXISTED=1; fi
LINK_MOVED=0
PATH_MOVED=0
DISCARDED=0
HELD=0
PLACED=0
COMMITTED=0

# retarget LINK TARGET replaces LINK with a symlink to TARGET by one rename, so LINK always resolves.
retarget() {
  local tmp="$1.tmp.$$"
  rm -f "$tmp"
  ln -s "$2" "$tmp"
  mv -fh "$tmp" "$1" || {
    rm -f "$tmp"
    return 1
  }
}

# Undo steps. On failure they print the command that finishes the undo by hand.
undo_move() { # undo_move FROM TO
  mv "$1" "$2" || echo "install-app: could not restore $2; run: mv '$1' '$2'" >&2
}

undo_link() { # undo_link LINK OLD_TARGET: point LINK back at OLD_TARGET, or remove it if it had none
  if [ -z "$2" ]; then
    rm -f "$1" || echo "install-app: could not remove $1" >&2
    return
  fi
  retarget "$1" "$2" || echo "install-app: could not restore $1; run: ln -sfh '$2' '$1'" >&2
}

on_exit() {
  local status=$?
  if [ "$COMMITTED" = 0 ]; then
    if [ "$PLACED" = 1 ]; then undo_move "$INSTALL_PATH" "$CANDIDATE"; fi
    if [ "$HELD" = 1 ]; then undo_move "$HOLD" "$INSTALL_PATH"; fi
    if [ "$DISCARDED" = 1 ]; then undo_move "$DISCARD" "$PREVIOUS"; fi
    if [ "$PATH_MOVED" = 1 ]; then
      if [ "$PATH_EXISTED" = 1 ] && [ -z "$PATH_OLD" ]; then
        echo "install-app: $PATH_LINK was a file and now links to $STABLE" >&2
      else
        undo_link "$PATH_LINK" "$PATH_OLD"
      fi
    fi
    if [ "$LINK_MOVED" = 1 ]; then undo_link "$STABLE" "$LINK_OLD"; fi
  fi
  if [ "$COMMITTED" = 1 ]; then rm -rf "$DISCARD"; fi
  if [ "$ROLLBACK" = 0 ]; then rm -rf "$STAGED"; fi
  rm -rf "$VERSIONS/.tmp.$$"
  rm -f "$STABLE.tmp.$$" "$PATH_LINK.tmp.$$"
  exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

qm_version() { QUESTMASTER_STATE_ROOT="$STATE_ROOT" "$1" version --json | plutil -extract version raw -o - -; }

# verify BUNDLE: a valid signature, and a qm whose stamped version matches the bundle's Info.plist.
verify() {
  local plist qm
  codesign --verify --deep --strict "$1" || die "$1: the signature does not verify"
  plist="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist")" ||
    die "$1: no CFBundleShortVersionString"
  qm="$(qm_version "$1/Contents/Resources/qm")" || die "$1: qm does not run"
  [ "$qm" != dev ] || die "$1: qm has no stamped version (built before staged installs?)"
  [ "$qm" = "$plist" ] || die "$1: qm reports $qm but Info.plist says $plist"
  [ -z "$EXPECT_VERSION" ] || [ "$qm" = "$EXPECT_VERSION" ] || die "$1: version $qm, expected $EXPECT_VERSION"
  case "$qm" in *[!A-Za-z0-9._+-]*) die "$1: version $qm is not a safe directory name" ;; esac
  VERSION="$qm"
}

# place QM: a verified copy of QM in its own versions directory, named by version and content hash,
# so a rebuild never overwrites a binary a session may be running.
place() {
  local hash tmp="$VERSIONS/.tmp.$$"
  hash="$(shasum -a 256 "$1" | cut -c1-12)"
  VERSION_DIR="$VERSIONS/$VERSION-$hash"
  if [ ! -x "$VERSION_DIR/qm" ]; then
    (umask 077 && mkdir -p "$VERSIONS")
    rm -rf "$tmp" "$VERSION_DIR"
    mkdir "$tmp"
    cp "$1" "$tmp/qm"
    chmod 755 "$tmp/qm"
    [ "$(qm_version "$tmp/qm")" = "$VERSION" ] || die "the copy of qm in $tmp does not run"
    mv "$tmp" "$VERSION_DIR"
  fi
  [ "$(shasum -a 256 "$VERSION_DIR/qm" | cut -c1-12)" = "$hash" ] || die "$VERSION_DIR/qm does not match $1"
}

# prune keeps the installed and the previous version, and any a daemon record names (a running
# daemon re-executed into it).
prune() {
  local keep record executable dir
  keep=" $(basename "$VERSION_DIR") "
  case "$LINK_OLD" in */bin/versions/*/qm) keep="$keep$(basename "$(dirname "$LINK_OLD")") " ;; esac
  for record in "$STATE_ROOT"/daemon/*.json; do
    [ -f "$record" ] || continue
    executable="$(plutil -extract executable raw -o - "$record" 2>/dev/null || true)"
    case "$executable" in */bin/versions/*/qm) keep="$keep$(basename "$(dirname "$executable")") " ;; esac
  done
  for dir in "$VERSIONS"/*; do
    [ -d "$dir" ] || continue
    case "$keep" in *" $(basename "$dir") "*) continue ;; esac
    rm -rf "$dir" || echo "install-app: could not remove $dir" >&2
  done
}

# A run killed outright skips its EXIT trap; remove what it left, named by its dead pid.
for leftover in "$INSTALL_PATH".staged.* "$PREVIOUS".discard.* "$VERSIONS"/.tmp.*; do
  [ -e "$leftover" ] || continue
  kill -0 "${leftover##*.}" 2>/dev/null || rm -rf "$leftover"
done

if [ "$ROLLBACK" = 0 ]; then
  rm -rf "$STAGED"
  ditto "$BUNDLE" "$STAGED"
fi
verify "$CANDIDATE"
# build-app.sh has already titled the run.
if [ -z "${UI_TITLED:-}" ]; then
  if [ "$ROLLBACK" = 1 ]; then ui_title "Restoring Questmaster $VERSION"; else ui_title "Installing Questmaster $VERSION"; fi
fi
ui_done "Checking the seal"
place "$CANDIDATE/Contents/Resources/qm"
ui_done "Storing qm"
(umask 077 && mkdir -p "$BIN_DIR/current")
mkdir -p "$(dirname "$PATH_LINK")"

# Commit: only renames from here. Each is recorded, and on_exit undoes them if a later one fails.
retarget "$STABLE" "$VERSION_DIR/qm"
LINK_MOVED=1
retarget "$PATH_LINK" "$STABLE"
PATH_MOVED=1
if [ "$ROLLBACK" = 0 ] && [ -e "$PREVIOUS" ]; then
  mv "$PREVIOUS" "$DISCARD"
  DISCARDED=1
fi
if [ -e "$INSTALL_PATH" ]; then
  mv "$INSTALL_PATH" "$HOLD"
  HELD=1
fi
mv "$CANDIDATE" "$INSTALL_PATH"
PLACED=1
if [ "$ROLLBACK" = 1 ] && [ "$HELD" = 1 ]; then mv "$HOLD" "$PREVIOUS"; fi
COMMITTED=1
ui_done "Swapping in the new build"

if [ "$ISOLATED" = 0 ]; then
  "$LSREGISTER" -f "$INSTALL_PATH" || echo "install-app: LaunchServices registration failed" >&2
fi
prune
if [ "$ISOLATED" = 0 ]; then
  if [ "${UI_STREAM}" = 1 ]; then
    "$STABLE" daemon check-upgrade || true
  else
    daemon_status="$("$STABLE" daemon check-upgrade 2>/dev/null || true)"
    case "$daemon_status" in
      *'"upgrade_started":true'*) ui_done "Rousing the daemon" "it moves to the new build" ;;
      *'"running":true'*) ui_done "Rousing the daemon" "already on this build" ;;
      *) ui_done "Rousing the daemon" "not running; the app starts it" ;;
    esac
  fi
fi

if [ "${UI_FANCY}" = 0 ]; then
  echo "Installed $INSTALL_PATH ($VERSION)"
  echo "Linked $STABLE -> $VERSION_DIR/qm"
  echo "Linked $PATH_LINK -> $STABLE"
  if [ -d "$PREVIOUS" ]; then echo "Kept $PREVIOUS (restore it with $0 --rollback)"; fi
  exit 0
fi
printf '\n  %s✦ Questmaster %s stands ready.%s\n\n' "${UI_GOLD}" "$VERSION" "${UI_RESET}"
ui_fact "App" "$(ui_tilde "$INSTALL_PATH")"
ui_fact "qm" "$(ui_tilde "$STABLE") → versions/$(basename "$VERSION_DIR")/qm"
ui_fact "PATH" "$(ui_tilde "$PATH_LINK") → $(ui_tilde "$STABLE")"
if [ -d "$PREVIOUS" ]; then ui_fact "Previous" "$(ui_tilde "$PREVIOUS")  ${UI_DIM}(install-app.sh --rollback)${UI_RESET}"; fi
echo
