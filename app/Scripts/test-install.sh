#!/usr/bin/env bash
# Tests install-app.sh against throwaway bundles. Everything it touches (HOME, the state root and
# the install path) lives in one temporary directory, and every run passes --isolated, so
# /Applications, ~/.local/bin, the real state root, LaunchServices and the daemon are never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$SCRIPT_DIR/install-app.sh"

T="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  chflags -R nouchg "$T" 2>/dev/null || true
  find "$T" -type l -exec chflags -h nouchg {} + 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

APP="$T/Applications/Questmaster.app"
PREVIOUS="$APP.previous"
STATE="$T/state"
STABLE="$STATE/bin/current/qm"
PATH_LINK="$T/home/.local/bin/questmaster"
mkdir -p "$T/Applications" "$T/home" "$T/bin"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

build_qm() { # build_qm STAMP OUT: an empty STAMP builds an unstamped qm that reports "dev"
  local ldflags=()
  if [ -n "$1" ]; then
    ldflags=(-ldflags "-X github.com/alexivison/questmaster/cmd.stampedVersion=$1")
  fi
  (cd "$REPO_ROOT" && go build -buildvcs=false ${ldflags[@]+"${ldflags[@]}"} -o "$2" .)
}

make_bundle() { # make_bundle PLIST_VERSION QM OUT
  mkdir -p "$3/Contents/MacOS" "$3/Contents/Resources"
  cat >"$3/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Questmaster</string>
<key>CFBundleIdentifier</key><string>com.example.questmaster-install-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$1</string>
</dict></plist>
EOF
  cp "$2" "$3/Contents/MacOS/Questmaster"
  cp "$2" "$3/Contents/Resources/qm"
  codesign --force --deep --sign - "$3" 2>/dev/null
}

plist_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
qm_version() { QUESTMASTER_STATE_ROOT="$STATE" "$1" version --json | plutil -extract version raw -o - -; }

install() { # install ARGS...: runs the installer on the isolated paths
  HOME="$T/home" QUESTMASTER_STATE_ROOT="$STATE" "$INSTALLER" --install-path "$APP" --isolated "$@"
}

# Everything a failed install must leave alone: the installed bundle (same inode, same version),
# the kept bundle, both links, and no staged copy beside the install path.
snapshot() {
  local inode="none" version="none" previous="none"
  if [ -d "$APP" ]; then
    inode="$(stat -f %i "$APP")"
    version="$(plist_version "$APP")"
  fi
  if [ -d "$PREVIOUS" ]; then
    previous="$(plist_version "$PREVIOUS")"
  fi
  echo "app=$inode:$version previous=$previous stable=$(readlink "$STABLE" || echo none)" \
    "path=$(readlink "$PATH_LINK" || echo none) dir=$(ls -A "$T/Applications" | tr '\n' ' ')"
}

expect_refused() { # expect_refused NAME ARGS...: the install fails and changes nothing
  local name="$1" before after
  shift
  before="$(snapshot)"
  if install "$@" >"$T/out" 2>&1; then
    cat "$T/out" >&2
    fail "$name: install succeeded"
  fi
  after="$(snapshot)"
  [ "$before" = "$after" ] || fail "$name: state changed
before: $before
after:  $after
$(cat "$T/out")"
  echo "ok - $name"
}

expect_installed() { # expect_installed VERSION: the app, the stable link and the PATH link all name VERSION
  [ "$(plist_version "$APP")" = "$1" ] || fail "installed app is $(plist_version "$APP"), want $1"
  case "$(readlink "$STABLE")" in
    "$STATE/bin/versions/$1-"*/qm) ;;
    *) fail "stable link points at $(readlink "$STABLE"), want a versions/$1-* copy" ;;
  esac
  [ "$(qm_version "$STABLE")" = "$1" ] || fail "stable qm reports $(qm_version "$STABLE"), want $1"
  [ "$(readlink "$PATH_LINK")" = "$STABLE" ] || fail "PATH link points at $(readlink "$PATH_LINK"), want $STABLE"
  for staged in "$APP".staged.*; do
    [ ! -e "$staged" ] || fail "a staged copy was left behind: $staged"
  done
}

version_dirs() { ls "$STATE/bin/versions" | sed 's/-[0-9a-f]*$//' | sort | tr '\n' ' '; }

build_qm "" "$T/bin/qm-dev"
build_qm v1-test "$T/bin/qm-v1"
build_qm v2-test "$T/bin/qm-v2"
build_qm v3-test "$T/bin/qm-v3"
build_qm v4-test "$T/bin/qm-v4"
make_bundle v1-test "$T/bin/qm-v1" "$T/v1/Questmaster.app"
make_bundle v2-test "$T/bin/qm-v2" "$T/v2/Questmaster.app"
make_bundle v3-test "$T/bin/qm-v3" "$T/v3/Questmaster.app"
make_bundle v4-test "$T/bin/qm-v4" "$T/v4/Questmaster.app"
make_bundle v3-test "$T/bin/qm-v2" "$T/mismatch/Questmaster.app"
make_bundle v3-test "$T/bin/qm-v3" "$T/tampered/Questmaster.app"
echo "tampered" >>"$T/tampered/Questmaster.app/Contents/Resources/qm"

# An install made by the old build script: the app's own qm is what both links name.
make_bundle 0.1.0 "$T/bin/qm-dev" "$APP"
mkdir -p "$(dirname "$STABLE")" "$(dirname "$PATH_LINK")"
ln -s "$APP/Contents/Resources/qm" "$STABLE"
ln -s "$APP/Contents/Resources/qm" "$PATH_LINK"

install --expect-version v1-test "$T/v1/Questmaster.app" >"$T/out" 2>&1 || {
  cat "$T/out" >&2
  fail "first install failed"
}
grep -q "Installed $APP (v1-test)" "$T/out" || fail "first install did not print the stamped version: $(cat "$T/out")"
expect_installed v1-test
V1_QM="$(readlink "$STABLE")"
[ "$(plist_version "$PREVIOUS")" = 0.1.0 ] || fail "the old app was not kept as $PREVIOUS"
echo "ok - first install over an old-style install prints v1-test and moves both links off the bundle"

expect_refused "rollback to a bundle from before stamped versions" --rollback

install "$T/v2/Questmaster.app" >"$T/out" 2>&1 || {
  cat "$T/out" >&2
  fail "second install failed"
}
expect_installed v2-test
[ "$(plist_version "$PREVIOUS")" = v1-test ] || fail "previous bundle is $(plist_version "$PREVIOUS"), want v1-test"
[ "$(version_dirs)" = "v1-test v2-test " ] || fail "versions are $(version_dirs), want v1-test v2-test"
echo "ok - second install keeps v1-test as the previous bundle and version"

expect_refused "qm and Info.plist disagree" "$T/mismatch/Questmaster.app"
expect_refused "bundle signature does not verify" "$T/tampered/Questmaster.app"
expect_refused "stamped version is not the one the build expects" --expect-version v9-test "$T/v3/Questmaster.app"

chflags uchg "$APP"
expect_refused "the installed app cannot be moved aside (links are restored)" "$T/v3/Questmaster.app"
chflags nouchg "$APP"

chflags -h uchg "$STABLE"
expect_refused "the stable link cannot be replaced" "$T/v3/Questmaster.app"
chflags -h nouchg "$STABLE"

before="$(snapshot)"
if lockf -t 0 "$STATE/bin/install.lock" env HOME="$T/home" QUESTMASTER_STATE_ROOT="$STATE" \
  "$INSTALLER" --install-path "$APP" --isolated "$T/v3/Questmaster.app" >"$T/out" 2>&1; then
  fail "an install ran while another held the lock"
fi
grep -q "already locked" "$T/out" || fail "a held lock was not reported: $(cat "$T/out")"
[ "$(snapshot)" = "$before" ] || fail "a locked-out install changed state"
echo "ok - a second install is refused while one holds the lock"

# A run killed outright leaves its staged copy behind; pid 99999 is above macOS's pid limit.
mkdir -p "$APP.staged.99999/Contents"
RECORD="$STATE/daemon/canonical.json"
mkdir -p "$(dirname "$RECORD")"
printf '{"executable":"%s"}\n' "$V1_QM" >"$RECORD"
install "$T/v3/Questmaster.app" >"$T/out" 2>&1 || {
  cat "$T/out" >&2
  fail "third install failed"
}
expect_installed v3-test
[ "$(plist_version "$PREVIOUS")" = v2-test ] || fail "previous bundle is $(plist_version "$PREVIOUS"), want v2-test"
[ "$(version_dirs)" = "v1-test v2-test v3-test " ] || fail "versions are $(version_dirs), want old record v1-test plus installed and previous versions"
echo "ok - a legacy versioned daemon record keeps its running binary during prune"

# New daemon records use the stable link, so they do not pin an old version after upgrade.
printf '{"executable":"%s"}\n' "$STABLE" >"$RECORD"
install "$T/v4/Questmaster.app" >"$T/out" 2>&1 || {
  cat "$T/out" >&2
  fail "fourth install failed"
}
expect_installed v4-test
[ "$(plist_version "$PREVIOUS")" = v3-test ] || fail "previous bundle is $(plist_version "$PREVIOUS"), want v3-test"
[ "$(version_dirs)" = "v3-test v4-test " ] || fail "versions are $(version_dirs), want the stable record not to pin v1-test or v2-test"
echo "ok - a stable daemon record does not keep superseded versions alive"

install --rollback >"$T/out" 2>&1 || {
  cat "$T/out" >&2
  fail "rollback failed"
}
expect_installed v3-test
[ "$(plist_version "$PREVIOUS")" = v4-test ] || fail "after rollback the previous bundle is $(plist_version "$PREVIOUS"), want v4-test"
echo "ok - rollback swaps the bundles and points the stable link at the restored version"

# Mixed real and temporary paths are refused before anything is touched. The "real" paths here are
# harmless directories inside the build tree, never /Applications or the user's HOME.
REAL_LIKE="$REPO_ROOT/app/.build/install-guard-test"
rm -rf "$REAL_LIKE"
mkdir -p "$REAL_LIKE/home"
if HOME="$T/home" QUESTMASTER_STATE_ROOT="$STATE" "$INSTALLER" --install-path "$REAL_LIKE/Questmaster.app" --isolated \
  "$T/v3/Questmaster.app" >"$T/out" 2>&1; then
  fail "a non-temporary install path with a temporary HOME was accepted"
fi
grep -q "temporary" "$T/out" || fail "mixed-path refusal did not explain itself: $(cat "$T/out")"
if HOME="$REAL_LIKE/home" QUESTMASTER_STATE_ROOT="$STATE" "$INSTALLER" --install-path "$APP" \
  "$T/v3/Questmaster.app" >"$T/out" 2>&1; then
  fail "a temporary install path with a non-temporary HOME was accepted"
fi
grep -q "temporary" "$T/out" || fail "mixed-path refusal did not explain itself: $(cat "$T/out")"
[ ! -e "$REAL_LIKE/Questmaster.app" ] && [ ! -e "$REAL_LIKE/home/.local" ] || fail "a refused run touched $REAL_LIKE"
rm -rf "$REAL_LIKE"
expect_installed v3-test
echo "ok - mixed temporary and real paths are refused"

echo "install tests passed"
