#!/usr/bin/env bash
# Package an unsigned iphoneos app for on-device re-signing with Feather.
set -euo pipefail
APP_PATH="${1:?Usage: package-ipa.sh /path/CallRelay.app /path/CallRelay.ipa}"
OUTPUT_PATH="${2:?Output IPA path is required}"
test -f "$APP_PATH/Info.plist"
test -f "$APP_PATH/CallRelay"
test -f "$APP_PATH/Frameworks/WebRTC.framework/WebRTC"
if ! /usr/bin/lipo -archs "$APP_PATH/CallRelay" | /usr/bin/grep -qw arm64; then
  echo 'Expected an arm64 iPhone application' >&2; exit 1
fi
mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callrelay-ipa.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Payload"
ditto --norsrc --noextattr --noqtn "$APP_PATH" "$STAGING_DIR/Payload/CallRelay.app"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGING_DIR/Payload" "$OUTPUT_PATH"
shasum -a 256 "$OUTPUT_PATH"
