#!/usr/bin/env bash
# Fake every prerequisite so these checks never use real tools or start a build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-build-requirements.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home" "$T/Applications"

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$T/tool" <<'EOF'
#!/bin/bash
case "${0##*/}" in
  uname)
    case "$1" in
      -s) echo "${TEST_OS:-Darwin}" ;;
      -m) echo "${TEST_ARCH:-arm64}" ;;
      *) exit 1 ;;
    esac
    ;;
  sw_vers) echo "${TEST_MACOS:-14.0}" ;;
  xcode-select) exit "${TEST_XCODE_STATUS:-0}" ;;
  swift)
    if [ "$1" = --version ]; then exit "${TEST_SWIFT_STATUS:-0}"; fi
    echo "unexpected compilation" >>"$TEST_BUILD_LOG"
    exit 1
    ;;
esac
EOF
chmod +x "$T/tool"
for tool in uname sw_vers xcode-select swift git go tmux; do
  ln -s "$T/tool" "$T/bin/$tool"
done
ln -s /bin/bash "$T/bin/bash"
ln -s /usr/bin/dirname "$T/bin/dirname"

check() { PATH="$T/bin" /bin/bash "$CHECK"; }

expect_refused() {
  local name="$1" message="$2"
  shift 2
  if env "$@" PATH="$T/bin" /bin/bash "$CHECK" >"$T/out" 2>&1; then
    fail "$name: accepted an unsupported setup"
  fi
  grep -Fq "$message" "$T/out" || fail "$name: missing guidance: $(cat "$T/out")"
  echo "ok - $name"
}

check || fail "supported setup was refused"
echo "ok - supported setup"
expect_refused "non-macOS" "requires macOS 14 or later" TEST_OS=Linux
expect_refused "Intel or Rosetta terminal" "requires Apple Silicon" TEST_ARCH=x86_64
expect_refused "older macOS" "requires macOS 14 or later" TEST_MACOS=13.7
expect_refused "missing Command Line Tools" "xcode-select --install" TEST_XCODE_STATUS=1
expect_refused "unusable Swift toolchain" "xcode-select --install" TEST_SWIFT_STATUS=1

rm "$T/bin/tmux"
expect_refused "missing tmux" "brew install tmux"
rm "$T/bin/go"
expect_refused "missing Go" "brew install go"
grep -Fq "brew install tmux" "$T/out" || fail "missing tools were not reported together"
rm "$T/bin/git"
expect_refused "missing Git" "Git is required"

# Exercise the build entry point: missing tmux must stop it before Swift compilation.
ln -s "$T/tool" "$T/bin/git"
ln -s "$T/tool" "$T/bin/go"
if PATH="$T/bin" HOME="$T/home" QUESTMASTER_STATE_ROOT="$T/state" TEST_BUILD_LOG="$T/build-log" \
  /bin/bash "$SCRIPT_DIR/build-app.sh" --install-path "$T/Applications/Questmaster.app" --isolated >"$T/out" 2>&1; then
  fail "the build accepted missing tmux"
fi
grep -Fq "brew install tmux" "$T/out" || fail "the build did not explain missing tmux: $(cat "$T/out")"
[ ! -e "$T/build-log" ] || fail "Swift compilation started before checking prerequisites"
[ ! -e "$T/Applications/Questmaster.app" ] || fail "the refused build installed an app"
echo "ok - missing tmux stops the build before compilation"

echo "build prerequisite tests passed"
