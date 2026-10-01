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
    "localizedDescription": "首版预览：CallKit、私钥配对、PCMU 电话音频、离线演示。需自行签名；真机通话与后台推送待联调。",
    "sha256": hashlib.sha256(args.ipa.read_bytes()).hexdigest(),
}
app = {
    "name": "CallRelay", "bundleIdentifier": info["CFBundleIdentifier"],
    "developerName": "JiangNanGenius", "subtitle": "Linux 蜂窝电话网关的 iPhone 客户端",
    "localizedDescription": "连接自有 Linux 蜂窝电话网关，通过 CallKit 与 WebRTC 接打电话。PolyForm Noncommercial：仅限非商业用途。提供未签名 IPA，由 Feather 使用你自己的证书和描述文件重新签名。后台来电需要包含 Push Notifications 的匹配描述文件与自有 APNs 服务。",
    "iconURL": icon, "tintColor": "198B58", "beta": True,
    "versions": [version], "version": version["version"], "versionDate": version["date"],
    "size": version["size"], "downloadURL": version["downloadURL"],
    "appPermissions": {"entitlements": ["aps-environment"], "privacy": [
        {"name": "NSMicrophoneUsageDescription", "usageDescription": info["NSMicrophoneUsageDescription"]},
        {"name": "NSCameraUsageDescription", "usageDescription": info["NSCameraUsageDescription"]},
    ]},
}
source = {"name": "CallRelay 非商业安装源", "identifier": "com.jiangnangenius.callrelay.source",
          "subtitle": "自行签名 · 首版预览", "website": base, "iconURL": icon,
          "tintColor": "198B58", "apps": [app], "news": []}
args.output.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
print(f"Wrote {args.output}: {version['version']}, {version['size']} bytes, SHA256 {version['sha256']}")
