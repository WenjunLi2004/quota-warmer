#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="/tmp/QuotaWarmerBuild"
APP_DEST="/Applications/QuotaWarmer.app"

cd "$ROOT_DIR"

echo "Building QuotaWarmer Release..."
xcodebuild -project QuotaWarmer.xcodeproj \
  -scheme QuotaWarmer \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  build

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
