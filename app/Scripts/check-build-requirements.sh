#!/usr/bin/env bash
# Check before compiling so a source install reports missing tools up front.
set -euo pipefail

if [ "$(uname -s)" != Darwin ]; then
  echo "Questmaster.app requires macOS 14 or later on Apple Silicon." >&2
  exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
  echo "Questmaster.app currently requires Apple Silicon. Run the build from a native arm64 terminal." >&2
  exit 1
fi
MACOS_VERSION="$(sw_vers -productVersion)"
if [ "${MACOS_VERSION%%.*}" -lt 14 ]; then
  echo "Questmaster.app requires macOS 14 or later; found $MACOS_VERSION." >&2
  exit 1
fi

missing=0
if ! xcode-select -p >/dev/null 2>&1 || ! swift --version >/dev/null 2>&1; then
  echo "Apple's Command Line Tools with Swift are required. Run: xcode-select --install" >&2
  missing=1
fi
if ! command -v git >/dev/null 2>&1; then
  echo "Git is required. Run: xcode-select --install" >&2
  missing=1
fi
if ! command -v go >/dev/null 2>&1; then
  echo "Go 1.25.7 or newer is required. With Homebrew installed, run: brew install go" >&2
  missing=1
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required to run sessions. With Homebrew installed, run: brew install tmux" >&2
  missing=1
fi
if [ "$missing" = 1 ]; then
  echo "Install the missing prerequisites, then run app/Scripts/build-app.sh again." >&2
  exit 1
fi
