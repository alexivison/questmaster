#!/usr/bin/env bash
set -euo pipefail

INSTALL_PATH="${QUESTMASTER_INSTALL_PATH:-/Applications/Questmaster.app}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --install-path)
      INSTALL_PATH="${2:?missing value for --install-path}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--install-path /Applications/Questmaster.app]" >&2
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

if [ ! -f "$ICNS_PATH" ]; then
  echo "missing app icon: $ICNS_PATH" >&2
  exit 1
fi

swift build -c release --package-path "$APP_DIR"
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"
SWIFTPM_RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 \( -name "Questmaster_Questmaster.bundle" -o -name "Questmaster_Questmaster.resources" \) -print -quit)"
if [ -z "$SWIFTPM_RESOURCE_BUNDLE" ]; then
  echo "missing SwiftPM resource bundle in $BIN_DIR" >&2
  exit 1
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources" "$BUNDLE_DIR/Contents/Frameworks"

cp "$INFO_PLIST" "$BUNDLE_DIR/Contents/Info.plist"
cp "$ICNS_PATH" "$BUNDLE_DIR/Contents/Resources/Questmaster.icns"
ditto "$SWIFTPM_RESOURCE_BUNDLE" "$BUNDLE_DIR/Contents/Resources/$(basename "$SWIFTPM_RESOURCE_BUNDLE")"
cp "$BIN_DIR/Questmaster" "$BUNDLE_DIR/Contents/MacOS/Questmaster"
chmod 755 "$BUNDLE_DIR/Contents/MacOS/Questmaster"

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

(cd "$REPO_ROOT" && go build -buildvcs=false -o "$BUNDLE_DIR/Contents/Resources/qm" .)
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

codesign --force --deep --sign - "$BUNDLE_DIR"
rm -rf "$INSTALL_PATH"
ditto "$BUNDLE_DIR" "$INSTALL_PATH"
codesign --verify --deep --strict "$INSTALL_PATH"

echo "Built $BUNDLE_DIR"
echo "Installed $INSTALL_PATH"
