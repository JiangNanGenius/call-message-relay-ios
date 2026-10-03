#!/usr/bin/env bash
#
# package-release-variants.sh — build and package BOTH unsigned CallRelay
# editions for one release: Feather native (Release) and App Store
# Bark/Shortcuts (Release-Bark), then verify each one and write the public
# SHA-256 list.
#
# Usage:
#   Scripts/package-release-variants.sh [options]
#
#   --app-native PATH    use a prebuilt native CallRelay.app (skips building)
#   --app-bark PATH      use a prebuilt Bark CallRelay.app (skips building)
#   --output-dir DIR     artifact directory (default build/feather-<ver>-<build>)
#   --jobs N             xcodebuild parallel jobs (default 6)
#
# Environment:
#   DERIVED_DATA_ROOT    cache root for device builds
#                        (default ~/Library/Caches/CodexBuild/callrelay/release-variants)
#
# The native edition is never allowed to contain the Bark/Shortcuts bridge and
# the Bark edition must contain it; both IPAs are unsigned (CODE_SIGNING_ALLOWED=NO)
# and neither may contain provisioning or signing material. See
# docs/release.md for the publication checklist.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_ROOT="${DERIVED_DATA_ROOT:-$HOME/Library/Caches/CodexBuild/callrelay/release-variants}"
JOBS="${JOBS:-6}"
NATIVE_APP=""
BARK_APP=""
OUTPUT_DIR=""

usage() { sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-native) NATIVE_APP="${2:?}"; shift 2 ;;
    --app-bark) BARK_APP="${2:?}"; shift 2 ;;
    --output-dir) OUTPUT_DIR="${2:?}"; shift 2 ;;
    --jobs) JOBS="${2:?}"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done

if { [ -n "$NATIVE_APP" ] && [ -z "$BARK_APP" ]; } || { [ -z "$NATIVE_APP" ] && [ -n "$BARK_APP" ]; }; then
  echo "ERROR: --app-native and --app-bark must be given together" >&2
  exit 2
fi

build_variant() { # configuration derived-data-suffix
  local config="$1"
  local suffix="$2"
  echo "== Building $config (unsigned, generic/platform=iOS) =="
  ( cd "$ROOT_DIR" && xcodebuild build \
      -project CallRelay.xcodeproj -scheme CallRelay \
      -configuration "$config" -destination 'generic/platform=iOS' \
      -derivedDataPath "$DERIVED_DATA_ROOT/$suffix" \
      -jobs "$JOBS" \
      CODE_SIGNING_ALLOWED=NO )
}

if [ -z "$NATIVE_APP" ]; then
  if [ ! -f "$ROOT_DIR/CallRelay.xcodeproj/project.pbxproj" ]; then
    echo "== Generating Xcode project =="
    ( cd "$ROOT_DIR" && xcodegen generate )
  fi
  build_variant Release native
  build_variant Release-Bark bark
  NATIVE_APP="$DERIVED_DATA_ROOT/native/Build/Products/Release-iphoneos/CallRelay.app"
  BARK_APP="$DERIVED_DATA_ROOT/bark/Build/Products/Release-Bark-iphoneos/CallRelay.app"
fi

[ -f "$NATIVE_APP/Info.plist" ] || { echo "ERROR: native app not found: $NATIVE_APP" >&2; exit 1; }
[ -f "$BARK_APP/Info.plist" ] || { echo "ERROR: bark app not found: $BARK_APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NATIVE_APP/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$NATIVE_APP/Info.plist")"
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { echo "ERROR: could not read version from $NATIVE_APP" >&2; exit 1; }

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/feather-$VERSION-$BUILD}"
mkdir -p "$OUTPUT_DIR"
NATIVE_IPA="$OUTPUT_DIR/CallRelay-Feather-Native-$VERSION-$BUILD-unsigned.ipa"
BARK_IPA="$OUTPUT_DIR/CallRelay-AppStore-Bark-$VERSION-$BUILD-unsigned.ipa"

"$ROOT_DIR/Scripts/package-ipa.sh" "$NATIVE_APP" "$NATIVE_IPA"
"$ROOT_DIR/Scripts/package-ipa.sh" "$BARK_APP" "$BARK_IPA"

"$ROOT_DIR/Scripts/verify-release-variant.sh" native "$NATIVE_IPA" --version "$VERSION" --build "$BUILD"
"$ROOT_DIR/Scripts/verify-release-variant.sh" bark "$BARK_IPA" --version "$VERSION" --build "$BUILD"

( cd "$OUTPUT_DIR" && shasum -a 256 CallRelay-*-unsigned.ipa > SHA256SUMS.public.txt )
echo "== Public assets in $OUTPUT_DIR =="
cat "$OUTPUT_DIR/SHA256SUMS.public.txt"
