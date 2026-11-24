#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "=== QuotaWarmer Local macOS Toolchain Setup ==="

# 1. Install xcodegen via Homebrew if missing.
if command -v xcodegen >/dev/null 2>&1; then
  echo "[OK] xcodegen is installed: $(command -v xcodegen)"
else
  if command -v brew >/dev/null 2>&1; then
    echo "Installing xcodegen via Homebrew..."
    HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
  else
    echo "WARNING: Homebrew is not installed, so xcodegen could not be auto-installed."
  fi
fi

# 2. Locate a full Xcode.app installation (CommandLineTools alone cannot build SwiftUI .xcodeproj apps).
XCODE_APP=""
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
  XCODE_APP="/Applications/Xcode.app"
else
  FIRST_XCODE="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
  if [ -n "$FIRST_XCODE" ] && [ -d "$FIRST_XCODE/Contents/Developer" ]; then
    XCODE_APP="$FIRST_XCODE"
  fi
fi

if [ -n "$XCODE_APP" ]; then
  CURRENT_DEV="$(xcode-select -p 2>/dev/null || true)"
  TARGET_DEV="$XCODE_APP/Contents/Developer"
  if [ "$CURRENT_DEV" != "$TARGET_DEV" ]; then
    echo "Pointing xcode-select to $TARGET_DEV (macOS may prompt for your password)..."
    sudo xcode-select -s "$TARGET_DEV"
  fi
  if ! xcodebuild -version >/dev/null 2>&1; then
    echo "Accepting Xcode license..."
    sudo xcodebuild -license accept
  fi
  echo "[OK] Full Xcode toolchain active: $(xcodebuild -version | tr '\n' ' ')"
  echo "Building from local source and restarting QuotaWarmer..."
  exec "$ROOT_DIR/scripts/local-package.command"
else
  echo ""
  echo "NOTE: Full /Applications/Xcode.app (~12 GB) is not installed on this Mac yet."
  echo "      macOS Command Line Tools alone cannot compile SwiftUI .xcodeproj bundles."
  echo "      Opening Xcode in Mac App Store if you want local source compilation later..."
  open "macappstore://itunes.apple.com/app/id497799835" >/dev/null 2>&1 || true
  echo ""
  echo "In the meantime, installing & restarting the latest prebuilt QuotaWarmer right now..."
  exec "$ROOT_DIR/scripts/install-dmg.command"
fi
