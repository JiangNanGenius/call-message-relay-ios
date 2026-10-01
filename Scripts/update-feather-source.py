#!/usr/bin/env python3
"""Generate a Feather source from the actual published IPA, never a guessed size."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("ipa", type=Path)
parser.add_argument("--tag", required=True)
parser.add_argument("--output", type=Path, default=Path("feather.json"))
parser.add_argument("--screenshot", action="append", default=[], help="Published screenshot filename beside the IPA")
args = parser.parse_args()
if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", args.tag):
    parser.error("Expected a version tag, for example v0.1.0")
with zipfile.ZipFile(args.ipa) as archive:
    info = plistlib.loads(archive.read("Payload/CallRelay.app/Info.plist"))
    archive.getinfo("Payload/CallRelay.app/CallRelay")
    archive.getinfo("Payload/CallRelay.app/Frameworks/WebRTC.framework/WebRTC")
repo = "JiangNanGenius/call-message-relay-ios"
base = f"https://github.com/{repo}"
icon = f"https://raw.githubusercontent.com/{repo}/main/CallRelay/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
version = {
    "version": info["CFBundleShortVersionString"],
    "buildVersion": info["CFBundleVersion"],
    "date": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
    "minOSVersion": info["MinimumOSVersion"],
    "size": args.ipa.stat().st_size,
    "downloadURL": f"{base}/releases/download/{args.tag}/{args.ipa.name}",
    "localizedDescription": "首版预览：CallKit、短信、通讯录去重导出、垃圾过滤与号码列表、自动重连及可选私有 iCloud 同步。跟随系统外观，提供离线演示。需自行签名；iCloud 另需匹配权限与容器。真实通话、短信、后台推送及跨设备同步待联调。",
    "sha256": hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
}
app = {
    "name": "CallRelay", "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": "JiangNanGenius", "subtitle": "Linux 蜂窝电话网关的 iPhone 客户端",
    "localizedDescription": "连接自有 Linux 蜂窝电话网关，通过 CallKit 与 WebRTC 接打电话，并收发短信。PolyForm Noncommercial：仅限非商业用途。提供未签名 IPA，由 Feather 使用你自己的证书和描述文件重新签名。后台来电需要匹配的 Push Notifications 描述文件与自有 APNs 服务；iCloud 同步还需要匹配的 iCloud 权限和容器。",
    "iconURL": icon, "tintColor": "135CDC", "beta": True,
    "versions": [version], "version": version["version"], "versionDate": version["date"],
    "size": version["size"], "downloadURL": version["downloadURL"],
    "appPermissions": {"entitlements": ["aps-environment"], "privacy": [
        {"name": "NSMicrophoneUsageDescription", "usageDescription": info["NSMicrophoneUsageDescription"]},
        {"name": "NSCameraUsageDescription", "usageDescription": info["NSCameraUsageDescription"]},
    ]},
}
if info.get("NSContactsUsageDescription"):
    app["appPermissions"]["privacy"].append({
        "name": "NSContactsUsageDescription",
        "usageDescription": info["NSContactsUsageDescription"],
    })
if args.screenshot:
    for name in args.screenshot:
        if Path(name).name != name or not name.endswith(".png") or not (args.ipa.parent / name).is_file():
            parser.error("Screenshots must be existing PNG files beside the IPA")
    app["screenshotURLs"] = [f"{base}/releases/download/{args.tag}/{name}" for name in args.screenshot]
source = {"name": "CallRelay 非商业安装源", "identifier": "com.jiangnangenius.callrelay.source",
          "subtitle": "自行签名 · 首版预览", "website": base, "iconURL": icon,
          "tintColor": "135CDC", "apps": [app], "news": []}
args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
print(f"Wrote {args.output}: {version['version']}, {version['size']} bytes, SHA256 {version['sha256']}")
