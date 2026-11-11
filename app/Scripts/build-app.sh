#!/usr/bin/env bash
set -euo pipefail

# Builds Questmaster.app, stamps it with the git version, and hands it to install-app.sh, which
# stages, verifies and swaps it in. --isolated is for test runs; see install-app.sh.
INSTALL_PATH="${QUESTMASTER_INSTALL_PATH:-/Applications/Questmaster.app}"
INSTALL_ARGS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-path)
      INSTALL_PATH="${2:?missing value for --install-path}"
      shift 2
      ;;
    --isolated)
      INSTALL_ARGS+=(--isolated)
      shift
      ;;
    *)
      echo "usage: $0 [--install-path /Applications/Questmaster.app] [--isolated]" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
BUNDLE_DIR="$APP_DIR/.build/app/Questmaster.app"
RESOURCES_DIR="$APP_DIR/Resources"
INFO_PLIST="$RESOURCES_DIR/Info.plist"
ICNS_PATH="$RESOURCES_DIR/Questmaster.icns"
UI_REPO_ROOT="$REPO_ROOT"
# shellcheck source-path=SCRIPTDIR source=output.sh
source "$SCRIPT_DIR/output.sh"

if [ ! -f "$ICNS_PATH" ]; then
  echo "missing app icon: $ICNS_PATH" >&2
  exit 1
fi

# One version for the whole bundle: Info.plist and the bundled qm report the same string, and
# install-app.sh refuses a bundle where they differ.
VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty --match 'v[0-9]*')"

ui_title "Forging Questmaster $VERSION"
ui_step "Compiling the app" swift build -c release --package-path "$APP_DIR"
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"
SWIFTPM_RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 \( -name "Questmaster_Questmaster.bundle" -o -name "Questmaster_Questmaster.resources" \) -print -quit)"
if [ -z "$SWIFTPM_RESOURCE_BUNDLE" ]; then
  echo "missing SwiftPM resource bundle in $BIN_DIR" >&2
  exit 1
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources" "$BUNDLE_DIR/Contents/Frameworks"

cp "$INFO_PLIST" "$BUNDLE_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE_DIR/Contents/Info.plist"
cp "$ICNS_PATH" "$BUNDLE_DIR/Contents/Resources/Questmaster.icns"
ditto "$SWIFTPM_RESOURCE_BUNDLE" "$BUNDLE_DIR/Contents/Resources/$(basename "$SWIFTPM_RESOURCE_BUNDLE")"
cp "$BIN_DIR/Questmaster" "$BUNDLE_DIR/Contents/MacOS/Questmaster"
chmod 755 "$BUNDLE_DIR/Contents/MacOS/Questmaster"
ui_done "Assembling the bundle"

find_ghostty_framework() {
  local root="$APP_DIR/.build/artifacts"
  if [ ! -d "$root" ]; then
    echo "missing SwiftPM artifacts directory: $root" >&2
    return 1
  fi

  find "$root" \
    \( -path "*/CGhosttyKitBinary.xcframework/macos-arm64/CGhosttyKitBinary.framework" \
    -o -path "*/GhosttyKit.xcframework/macos-arm64/CGhosttyKitBinary.framework" \) \
    -type d \
    -print \
    -quit
}

GHOSTTY_FRAMEWORK="$(find_ghostty_framework)"
if [ -z "$GHOSTTY_FRAMEWORK" ]; then
  echo "CGhosttyKitBinary.framework not found in SwiftPM artifacts" >&2
  exit 1
fi

ditto "$GHOSTTY_FRAMEWORK" "$BUNDLE_DIR/Contents/Frameworks/CGhosttyKitBinary.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BUNDLE_DIR/Contents/MacOS/Questmaster" 2>/dev/null || true
ui_done "Binding the Ghostty terminal"

ui_step "Forging qm" go -C "$REPO_ROOT" build -buildvcs=false -ldflags "-X github.com/alexivison/questmaster/cmd.stampedVersion=$VERSION" -o "$BUNDLE_DIR/Contents/Resources/qm" .
chmod 755 "$BUNDLE_DIR/Contents/Resources/qm"

if [ ! -x "$BUNDLE_DIR/Contents/Resources/qm" ]; then
  echo "bundled qm is not executable" >&2
  exit 1
fi
if [ ! -d "$BUNDLE_DIR/Contents/Frameworks/CGhosttyKitBinary.framework" ]; then
  echo "missing bundled Ghostty framework" >&2
  exit 1
fi
if [ ! -s "$BUNDLE_DIR/Contents/Resources/Questmaster.icns" ]; then
  echo "missing bundled app icon" >&2
  exit 1
fi
if [ ! -s "$BUNDLE_DIR/Contents/Resources/$(basename "$SWIFTPM_RESOURCE_BUNDLE")/claude.svg" ]; then
  echo "missing bundled SwiftPM agent logo resources" >&2
  exit 1
fi
if [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUNDLE_DIR/Contents/Info.plist")" != "14.0" ]; then
  echo "Info.plist LSMinimumSystemVersion must match macOS 14 target" >&2
  exit 1
fi

ui_step "Sealing the bundle" codesign --force --deep --sign - "$BUNDLE_DIR"
[ "${UI_FANCY}" = 1 ] || echo "Built $BUNDLE_DIR ($VERSION)"

UI_TITLED=1 "$SCRIPT_DIR/install-app.sh" --install-path "$INSTALL_PATH" --expect-version "$VERSION" ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"} "$BUNDLE_DIR"
