#!/usr/bin/env bash
#
# verify-release-variant.sh — prove a built CallRelay app/IPA is the right edition.
#
# Usage:
#   Scripts/verify-release-variant.sh native <CallRelay.app|.ipa> [--version X] [--build N]
#   Scripts/verify-release-variant.sh bark   <CallRelay.app|.ipa> [--version X] [--build N]
#
# Native (Feather) must contain no Bark/Shortcuts bridge: no AppIntents
# metadata, no callrelay:// URL scheme, no BarkBridge.strings, no Bark symbols.
# Bark (App Store edition) must contain that bridge. Both public artifacts must
# be unsigned: no embedded.mobileprovision, no _CodeSignature, no signing
# identity/device data.
set -euo pipefail

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -ge 2 ] || usage
VARIANT="$1"; shift
case "$VARIANT" in
  native|bark) ;;
  *) echo "ERROR: variant must be 'native' or 'bark'" >&2; usage ;;
esac
ARTIFACT="$1"; shift
EXPECT_VERSION=""
EXPECT_BUILD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) EXPECT_VERSION="${2:?}"; shift 2 ;;
    --build) EXPECT_BUILD="${2:?}"; shift 2 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage ;;
  esac
done
[ -e "$ARTIFACT" ] || { echo "ERROR: not found: $ARTIFACT" >&2; exit 2; }

WORK_DIR=""
cleanup() { [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [ -d "$ARTIFACT" ]; then
  APP="$ARTIFACT"
  case "$APP" in *.app) ;; *) echo "ERROR: expected a .app bundle: $APP" >&2; exit 2 ;; esac
elif [ -f "$ARTIFACT" ]; then
  case "$ARTIFACT" in
    *.ipa) ;;
    *) echo "ERROR: expected a .app bundle or .ipa: $ARTIFACT" >&2; exit 2 ;;
  esac
  if unzip -l "$ARTIFACT" | grep -Eq 'embedded\.mobileprovision|_CodeSignature'; then
    echo "FAIL: IPA contains signing material (embedded.mobileprovision/_CodeSignature)" >&2
    exit 1
  fi
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/callrelay-verify.XXXXXX")"
  unzip -q "$ARTIFACT" -d "$WORK_DIR"
  APP="$WORK_DIR/Payload/CallRelay.app"
else
  echo "ERROR: not a file or directory: $ARTIFACT" >&2; exit 2
fi
[ -f "$APP/Info.plist" ] || { echo "ERROR: no Info.plist in $APP" >&2; exit 2; }
[ -x "$APP/CallRelay" ] || { echo "ERROR: no CallRelay executable in $APP" >&2; exit 2; }

fail() { echo "FAIL: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist" 2>/dev/null; }
string_matches() { # file, extended-regex -> count
  strings -a "$1" | grep -Eic "$2" || true
}

# --- common: unsigned + version -------------------------------------------------
if find "$APP" \( -name embedded.mobileprovision -o -name _CodeSignature \) -print -quit | grep -q .; then
  fail "bundle carries a provisioning profile or code signature"
fi
CODESIGN_OUT="$(/usr/bin/codesign -dv "$APP" 2>&1 || true)"
# `codesign -dv` exits non-zero for unsigned objects; pipefail would otherwise
# turn the expected unsigned result into a failure.
grep -q "code object is not signed" <<<"$CODESIGN_OUT" \
  || fail "app bundle appears signed (codesign -dv did not report an unsigned object)"

ACTUAL_VERSION="$(plist CFBundleShortVersionString)"
ACTUAL_BUILD="$(plist CFBundleVersion)"
[ -n "$ACTUAL_VERSION" ] && [ -n "$ACTUAL_BUILD" ] || fail "missing CFBundleShortVersionString/CFBundleVersion"
if [ -n "$EXPECT_VERSION" ] && [ "$ACTUAL_VERSION" != "$EXPECT_VERSION" ]; then
  fail "version $ACTUAL_VERSION != expected $EXPECT_VERSION"
fi
if [ -n "$EXPECT_BUILD" ] && [ "$ACTUAL_BUILD" != "$EXPECT_BUILD" ]; then
  fail "build $ACTUAL_BUILD != expected $EXPECT_BUILD"
fi

BARK_PATTERN='bark|IncomingCallChecker|CheckIncomingCallIntent|callrelay://incoming'
if [ "$VARIANT" = "native" ]; then
  # --- native (Feather): bridge must be absent ---------------------------------
  [ ! -d "$APP/Metadata.appintents" ] || fail "native app contains Metadata.appintents (Bark/Shortcuts bridge)"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleURLTypes" "$APP/Info.plist" >/dev/null 2>&1; then
    fail "native Info.plist declares CFBundleURLTypes (callrelay:// must not exist)"
  fi
  if find "$APP" -name BarkBridge.strings -print -quit | grep -q .; then
    fail "native bundle contains BarkBridge.strings"
  fi
  BIN_MATCHES="$(string_matches "$APP/CallRelay" "$BARK_PATTERN")"
  [ "$BIN_MATCHES" = "0" ] || fail "native executable contains $BIN_MATCHES Bark bridge symbol(s)"
  while IFS= read -r f; do
    n="$(string_matches "$f" 'Bark')"
    [ "$n" = "0" ] || fail "native localization $f contains $n Bark string(s)"
  done < <(find "$APP" -name '*.strings')
  echo "PASS native: $ACTUAL_VERSION ($ACTUAL_BUILD), unsigned, no AppIntents/URL scheme/BarkBridge/strings/binary symbols"
else
  # --- bark (App Store edition): bridge must be present -------------------------
  [ -d "$APP/Metadata.appintents" ] || fail "bark app is missing Metadata.appintents"
  if ! plist CFBundleURLTypes | grep -q callrelay; then
    fail "bark Info.plist does not declare the callrelay URL scheme"
  fi
  for lang in en zh-Hans zh-Hant; do
    [ -f "$APP/$lang.lproj/BarkBridge.strings" ] || fail "bark bundle missing $lang.lproj/BarkBridge.strings"
  done
  BIN_MATCHES="$(string_matches "$APP/CallRelay" "$BARK_PATTERN")"
  [ "$BIN_MATCHES" -gt 0 ] || fail "bark executable contains no Bark bridge symbols"
  echo "PASS bark: $ACTUAL_VERSION ($ACTUAL_BUILD), unsigned, AppIntents + callrelay:// + BarkBridge.strings present ($BIN_MATCHES binary symbol matches)"
fi
