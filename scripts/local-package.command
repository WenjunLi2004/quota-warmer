#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/QuotaWarmerBuild"
APP_DEST="/Applications/QuotaWarmer.app"

cd "$ROOT_DIR"

# Regenerate the Xcode project so newly added/removed sources and any project.yml
# change (version, entitlements, build settings) are actually part of this build.
# Without this the build can silently use a stale .xcodeproj.
if command -v xcodegen >/dev/null 2>&1; then
  echo "Regenerating Xcode project from project.yml..."
  xcodegen generate
else
  echo "ERROR: xcodegen not found; cannot guarantee the project matches project.yml."
  echo "       Install it with: brew install xcodegen"
  exit 1
fi

echo "Building QuotaWarmer Release..."
xcodebuild -project QuotaWarmer.xcodeproj \
  -scheme QuotaWarmer \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  build

# Quit the running instance first. macOS will not start a second copy of an app
# that is already running, so `open` at the end would just re-focus the OLD build
# and the new binary would never run. Also avoids replacing a live bundle on disk.
if pgrep -x QuotaWarmer >/dev/null 2>&1; then
  echo "Quitting running QuotaWarmer..."
  osascript -e 'quit app "QuotaWarmer"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x QuotaWarmer >/dev/null 2>&1 || break
    sleep 0.25
  done
  if pgrep -x QuotaWarmer >/dev/null 2>&1; then
    echo "Graceful quit timed out; force-killing..."
    pkill -x QuotaWarmer || true
    sleep 1
  fi
fi

echo "Replacing existing app in /Applications..."
if [ -d "$APP_DEST" ]; then
  rm -rf "$APP_DEST"
fi

ditto "$BUILD_DIR/Build/Products/Release/QuotaWarmer.app" "$APP_DEST"
xattr -cr "$APP_DEST"

# Sign with a stable identity so the Keychain "Always Allow" grant survives
# rebuilds. An ad-hoc signature changes hash every build, which invalidates the
# grant and re-triggers the login-password prompt on each launch.
# Override with QW_SIGN_IDENTITY; otherwise use the first Apple Development cert.
SIGN_IDENTITY="${QW_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with stable identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DEST"
else
  echo "WARNING: no Apple Development identity found; leaving ad-hoc signature."
  echo "         The Keychain prompt will keep reappearing after each rebuild."
fi

echo "Opening QuotaWarmer..."
open "$APP_DEST"

# Confirm the freshly installed build is the one now running.
for _ in $(seq 1 20); do
  pgrep -x QuotaWarmer >/dev/null 2>&1 && break
  sleep 0.25
done
if pgrep -x QuotaWarmer >/dev/null 2>&1; then
  VERSION="$(defaults read "$APP_DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
  echo "QuotaWarmer $VERSION is running (pid $(pgrep -x QuotaWarmer | tr '\n' ' '))."
else
  echo "WARNING: QuotaWarmer did not appear in the process list after launch."
  exit 1
fi
