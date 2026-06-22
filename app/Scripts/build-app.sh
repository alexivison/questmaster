#!/usr/bin/env bash
set -euo pipefail

ICON_VARIANT="${QUESTMASTER_ICON_VARIANT:-A}"
INSTALL_PATH="${QUESTMASTER_INSTALL_PATH:-/Applications/Questmaster.app}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --icon)
      ICON_VARIANT="${2:?missing value for --icon}"
      shift 2
      ;;
    --install-path)
      INSTALL_PATH="${2:?missing value for --install-path}"
      shift 2
      ;;
    *)
      echo "usage: $0 [--icon A|B|C] [--install-path /Applications/Questmaster.app]" >&2
      exit 2
      ;;
  esac
done

ICON_VARIANT="$(printf '%s' "$ICON_VARIANT" | tr '[:lower:]' '[:upper:]')"
case "$ICON_VARIANT" in
  A|B|C) ;;
  *)
    echo "icon variant must be A, B, or C" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_DIR/.." && pwd)"
REPORT_DIR="${QUESTMASTER_REPORT_DIR:-$HOME/.docs/reports}"
REPORT_DATE="${QUESTMASTER_REPORT_DATE:-$(date +%F)}"
ICON_WORK_DIR="$APP_DIR/.build/icon-candidates"
ICONSET_DIR="$APP_DIR/.build/Questmaster.iconset"
BUNDLE_DIR="$APP_DIR/.build/app/Questmaster.app"
RESOURCES_DIR="$APP_DIR/Resources"
INFO_PLIST="$RESOURCES_DIR/Info.plist"
ICNS_PATH="$RESOURCES_DIR/Questmaster.icns"

mkdir -p "$RESOURCES_DIR" "$REPORT_DIR"

swift "$SCRIPT_DIR/render-icons.swift" \
  --output "$ICON_WORK_DIR" \
  --reports "$REPORT_DIR" \
  --report-date "$REPORT_DATE"

SELECTED_ICON="$ICON_WORK_DIR/QuestmasterIcon-$ICON_VARIANT.png"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

make_icon() {
  local point_size="$1"
  local scale="$2"
  local suffix=""
  local pixels=$((point_size * scale))
  if [ "$scale" -eq 2 ]; then
    suffix="@2x"
  fi
  sips -z "$pixels" "$pixels" "$SELECTED_ICON" \
    --out "$ICONSET_DIR/icon_${point_size}x${point_size}${suffix}.png" >/dev/null
}

make_icon 16 1
make_icon 16 2
make_icon 32 1
make_icon 32 2
make_icon 128 1
make_icon 128 2
make_icon 256 1
make_icon 256 2
make_icon 512 1
make_icon 512 2
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

swift build -c release --package-path "$APP_DIR"
BIN_DIR="$(swift build -c release --package-path "$APP_DIR" --show-bin-path)"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources" "$BUNDLE_DIR/Contents/Frameworks"

cp "$INFO_PLIST" "$BUNDLE_DIR/Contents/Info.plist"
cp "$ICNS_PATH" "$BUNDLE_DIR/Contents/Resources/Questmaster.icns"
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

codesign --force --deep --sign - "$BUNDLE_DIR"
rm -rf "$INSTALL_PATH"
ditto "$BUNDLE_DIR" "$INSTALL_PATH"
codesign --verify --deep --strict "$INSTALL_PATH"

echo "Built $BUNDLE_DIR"
echo "Installed $INSTALL_PATH"
echo "Icon variant $ICON_VARIANT"
