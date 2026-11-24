#!/bin/bash
set -euo pipefail

REPO="${QW_GITHUB_REPO:-WenjunLi2004/quota-warmer}"
TAG="${1:-v1.10.0-rc.2}"
VERSION="${TAG#v}"
DMG_NAME="QuotaWarmer-${VERSION}-universal.dmg"
BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"
TMP_DIR="$(mktemp -d /tmp/QuotaWarmerDMG.XXXXXX)"
MOUNT_DIR="${TMP_DIR}/mount"
APP_DEST="/Applications/QuotaWarmer.app"

cleanup() {
  if mount | grep -q "on ${MOUNT_DIR} "; then
    hdiutil detach "${MOUNT_DIR}" -quiet || true
  fi
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "Downloading ${DMG_NAME} (${TAG}) from ${REPO}..."
curl -fL --retry 3 -o "${TMP_DIR}/${DMG_NAME}" "${BASE_URL}/${DMG_NAME}"
curl -fsSL --retry 3 -o "${TMP_DIR}/${DMG_NAME}.sha256" "${BASE_URL}/${DMG_NAME}.sha256"

EXPECTED_SHA="$(awk '{print $1}' "${TMP_DIR}/${DMG_NAME}.sha256")"
ACTUAL_SHA="$(shasum -a 256 "${TMP_DIR}/${DMG_NAME}" | awk '{print $1}')"
if [[ -z "${EXPECTED_SHA}" || "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]]; then
  echo "ERROR: SHA-256 mismatch! Expected ${EXPECTED_SHA}, got ${ACTUAL_SHA}"
  exit 1
fi
echo "SHA-256 verified: ${ACTUAL_SHA}"

mkdir -p "${MOUNT_DIR}"
hdiutil attach "${TMP_DIR}/${DMG_NAME}" -nobrowse -readonly -mountpoint "${MOUNT_DIR}" -quiet

if [[ ! -d "${MOUNT_DIR}/QuotaWarmer.app" ]]; then
  echo "ERROR: QuotaWarmer.app not found inside mounted DMG."
  exit 1
fi

if pgrep -x QuotaWarmer >/dev/null 2>&1; then
  echo "Quitting running QuotaWarmer..."
  osascript -e 'quit app "QuotaWarmer"' >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x QuotaWarmer >/dev/null 2>&1 || break
    sleep 0.25
  done
  if pgrep -x QuotaWarmer >/dev/null 2>&1; then
    pkill -x QuotaWarmer || true
    sleep 1
  fi
fi

echo "Installing QuotaWarmer.app to /Applications..."
rm -rf "${APP_DEST}"
ditto "${MOUNT_DIR}/QuotaWarmer.app" "${APP_DEST}"
xattr -cr "${APP_DEST}"

echo "Opening QuotaWarmer..."
open "${APP_DEST}"

for _ in $(seq 1 20); do
  pgrep -x QuotaWarmer >/dev/null 2>&1 && break
  sleep 0.25
done
if pgrep -x QuotaWarmer >/dev/null 2>&1; then
  INSTALLED_VER="$(defaults read "${APP_DEST}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
  echo "QuotaWarmer ${INSTALLED_VER} is installed and running (pid $(pgrep -x QuotaWarmer | tr '\n' ' '))."
else
  echo "WARNING: QuotaWarmer did not appear in the process list after launch."
  exit 1
fi
