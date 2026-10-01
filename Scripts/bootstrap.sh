#!/usr/bin/env bash
#
# bootstrap.sh — fetch and verify the pinned WebRTC M151 binary.
#
# Why this exists: the stasel/WebRTC Swift package tag 151.0.0 points at a
# release asset URL that currently 404s. The byte-identical M151 binary was
# republished under release tag 151.0.1 with the SAME digest, so we pin the
# digest (not trust the tag) and verify it after download.
#
# The xcframework is extracted to Vendor/WebRTC/WebRTC.xcframework and is
# intentionally ignored by git. Run this before the first xcodebuild/CI.
set -euo pipefail

PINNED_SHA256="6f3f5693383ce65763190c46ca9f2c4325c34b83681acb9db30f01488e15f1e0"
ASSET_NAME="WebRTC-M151.xcframework.zip"
# Primary URL is the republished-but-identical asset; fall back to the original.
URLS=(
  "https://github.com/stasel/WebRTC/releases/download/151.0.1/${ASSET_NAME}"
  "https://github.com/stasel/WebRTC/releases/download/151.0.0/${ASSET_NAME}"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/WebRTC"
ZIP_PATH="${VENDOR_DIR}/${ASSET_NAME}"
XCFRAMEWORK="${VENDOR_DIR}/WebRTC.xcframework"

if [ -d "${XCFRAMEWORK}" ]; then
  echo "WebRTC.xcframework already present; nothing to do."
  exit 0
fi

mkdir -p "${VENDOR_DIR}"
downloaded=0
for url in "${URLS[@]}"; do
  echo "Fetching ${url}"
  if curl -fL --retry 3 -o "${ZIP_PATH}" "${url}"; then
    downloaded=1
    break
  fi
  echo "  ... unavailable, trying next source."
done
if [ "${downloaded}" -ne 1 ]; then
  echo "ERROR: could not download ${ASSET_NAME} from any source." >&2
  exit 1
fi

actual="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
if [ "${actual}" != "${PINNED_SHA256}" ]; then
  echo "ERROR: checksum mismatch." >&2
  echo "  expected ${PINNED_SHA256}" >&2
  echo "  actual   ${actual}" >&2
  rm -f "${ZIP_PATH}"
  exit 1
fi
echo "Checksum verified: ${actual}"

unzip -q -o "${ZIP_PATH}" -d "${VENDOR_DIR}"
rm -f "${ZIP_PATH}"
echo "Extracted ${XCFRAMEWORK}"
