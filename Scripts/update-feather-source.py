#!/usr/bin/env python3
"""Generate the Feather source (feather.json) from an actual published IPA.

The Feather source must always point at the pure-native edition: the IPA is
checked for the absence of any bridge (no callrelay:// URL scheme, no
WebPushBridge.strings, no Bark remnants, no bridge symbols) before any
version entry is written. File size and SHA-256 are read from the IPA
itself; the download URL is the GitHub release asset URL.

With --feed an existing source is updated in place (history and screenshots
are preserved, the generated version replaces any entry with the same
version+build). Without --feed a single-version source is produced.
"""
import argparse
import datetime
import hashlib
import json
import plistlib
import re
import zipfile
from pathlib import Path

REPO = "JiangNanGenius/call-message-relay-ios"
BASE = f"https://github.com/{REPO}"
ICON = (
    f"https://raw.githubusercontent.com/{REPO}/main/"
    "CallRelay/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)
DEFAULT_SOURCE_SUBTITLE = "Linux 网关的 iPhone 电话与短信客户端"
DEFAULT_APP_SUBTITLE = "Linux 蜂窝电话网关的 iPhone 客户端"
DEFAULT_DESCRIPTION = (
    "CallRelay {version}（build {build}）纯原生版：不含任何网页推送桥接。"
    "未签名 IPA，需自行使用证书与描述文件签名后安装。"
)
NATIVE_FORBIDDEN_BINARY = re.compile(
    rb"(?i)bark|webpush|web push|IncomingCallChecker|CheckIncomingCallIntent|callrelay://incoming"
)
# Swift symbol mangling artifact: identifiers ending in lowercase "bar"
# ("Toolbar", "Tabbar", ...) adjacent to the kind letter K produce the exact
# bytes "barK" (e.g. `AA07ToolbarK0Rd__lF`). Verified false positive — this
# exact spelling is excluded; EVERY other case (Bark, bark:// endpoints,
# BARK, WebPush, ...) still fails the check.
BARK_MANGLE_ARTIFACT = re.compile(rb"barK")


def has_bridge_content(data: bytes) -> bool:
    """True when a bridge-specific identifier/endpoint is present. Only the
    exact `barK` mangling artifact is ignored; real bark/Bark markers in any
    other case still reject the package."""
    for match in NATIVE_FORBIDDEN_BINARY.finditer(data):
        if BARK_MANGLE_ARTIFACT.fullmatch(match.group()) is None:
            return True
    return False

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("ipa", type=Path)
parser.add_argument("--tag", required=True, help="Published release tag, e.g. v0.3.6")
parser.add_argument("--output", type=Path, default=Path("feather.json"))
parser.add_argument("--feed", type=Path, help="Existing source JSON to update")
parser.add_argument("--description", help="Consumer description for this version")
parser.add_argument("--date", help="ISO-8601 UTC release date (default: now)")
parser.add_argument("--version", help="Assert the expected CFBundleShortVersionString")
parser.add_argument("--build", help="Assert the expected CFBundleVersion")
parser.add_argument("--source-subtitle", default=DEFAULT_SOURCE_SUBTITLE)
parser.add_argument("--app-subtitle", default=DEFAULT_APP_SUBTITLE)
parser.add_argument("--screenshot", action="append", default=[],
                    help="Published screenshot filename beside the IPA")
args = parser.parse_args()

if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", args.tag):
    parser.error("Expected a version tag, for example v0.3.6")
if not args.ipa.is_file():
    parser.error(f"IPA not found: {args.ipa}")

with zipfile.ZipFile(args.ipa) as archive:
    names = archive.namelist()
    app_prefix = next(
        (n for n in names if n.startswith("Payload/") and n.endswith(".app/")), None
    )
    if app_prefix is None:
        parser.error("IPA has no Payload/<app>.app")
    forbidden_paths = [
        n for n in names
        if n.endswith("BarkBridge.strings")
        or n.endswith("WebPushBridge.strings")
    ]
    if forbidden_paths:
        parser.error(
            "IPA is not the pure native edition (bridge files present): "
            + ", ".join(forbidden_paths[:3])
        )
    # Metadata.appintents ships in both editions since 0.3.35 (core App
    # Intents); only bridge REFERENCES inside it disqualify the native IPA.
    meta_prefix = app_prefix + "Metadata.appintents/"
    meta_files = [n for n in names if n.startswith(meta_prefix) and not n.endswith("/")]
    for name in meta_files:
        if has_bridge_content(archive.read(name)):
            parser.error(
                "IPA is not the pure native edition (bridge reference in "
                f"{name.replace(app_prefix, '')})"
            )
    info = plistlib.loads(archive.read(app_prefix + "Info.plist"))
    if info.get("CFBundleURLTypes"):
        parser.error("IPA is not the pure native edition (CFBundleURLTypes present)")
    executable = info.get("CFBundleExecutable", "CallRelay")
    archive.getinfo(app_prefix + executable)
    archive.getinfo(app_prefix + "Frameworks/WebRTC.framework/WebRTC")
    binary = archive.read(app_prefix + executable)
    if has_bridge_content(binary):
        parser.error("IPA is not the pure native edition (bridge symbols in the binary)")

version = info["CFBundleShortVersionString"]
build = info["CFBundleVersion"]
if args.version and version != args.version:
    parser.error(f"IPA version {version} != --version {args.version}")
if args.build and build != args.build:
    parser.error(f"IPA build {build} != --build {args.build}")

for name in args.screenshot:
    if Path(name).name != name or not name.endswith(".png") or not (args.ipa.parent / name).is_file():
        parser.error("Screenshots must be existing PNG files beside the IPA")

date = args.date or (
    datetime.datetime.now(datetime.timezone.utc)
    .isoformat(timespec="seconds")
    .replace("+00:00", "Z")
)
description = args.description or DEFAULT_DESCRIPTION.format(version=version, build=build)
size = args.ipa.stat().st_size
sha256 = hashlib.sha256(args.ipa.read_bytes()).hexdigest()
download_url = f"{BASE}/releases/download/{args.tag}/{args.ipa.name}"

entry = {
    "version": version,
    "buildVersion": build,
    "date": date,
    "minOSVersion": info["MinimumOSVersion"],
    "size": size,
    "downloadURL": download_url,
    "localizedDescription": description,
    "sha256": sha256,
}
privacy = [
    {"name": "NSMicrophoneUsageDescription", "usageDescription": info["NSMicrophoneUsageDescription"]},
    {"name": "NSCameraUsageDescription", "usageDescription": info["NSCameraUsageDescription"]},
]
if info.get("NSContactsUsageDescription"):
    privacy.append({
        "name": "NSContactsUsageDescription",
        "usageDescription": info["NSContactsUsageDescription"],
    })
app = {
    "name": "CallRelay",
    "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": "JiangNanGenius",
    "subtitle": args.app_subtitle,
    "localizedDescription": description,
    "iconURL": ICON,
    "tintColor": "135CDC",
    "beta": True,
    "versions": [entry],
    "version": version,
    "versionDate": date,
    "size": size,
    "downloadURL": download_url,
    "appPermissions": {"entitlements": ["aps-environment"], "privacy": privacy},
}
if args.screenshot:
    app["screenshotURLs"] = [
        f"{BASE}/releases/download/{args.tag}/{name}" for name in args.screenshot
    ]

if args.feed:
    existing = json.loads(args.feed.read_text())
    old_app = (existing.get("apps") or [{}])[0]
    old_versions = [
        v for v in old_app.get("versions", [])
        if not (v.get("version") == version and v.get("buildVersion") == build)
    ]
    app["versions"] = [entry, *old_versions]
    if not args.screenshot and old_app.get("screenshotURLs"):
        app["screenshotURLs"] = old_app["screenshotURLs"]
    source = {
        "name": "CallRelay",
        "identifier": existing.get("identifier", "com.jiangnangenius.callrelay.source"),
        "subtitle": args.source_subtitle,
        "website": BASE,
        "iconURL": ICON,
        "tintColor": "135CDC",
        "apps": [app],
        "news": existing.get("news", []),
    }
else:
    source = {
        "name": "CallRelay",
        "identifier": "com.jiangnangenius.callrelay.source",
        "subtitle": args.source_subtitle,
        "website": BASE,
        "iconURL": ICON,
        "tintColor": "135CDC",
        "apps": [app],
        "news": [],
    }

args.output.write_text(json.dumps(source, ensure_ascii=False, indent=1) + "\n")
print(
    f"Wrote {args.output}: native {version} ({build}), {size} bytes, "
    f"SHA256 {sha256}, {download_url}"
)
